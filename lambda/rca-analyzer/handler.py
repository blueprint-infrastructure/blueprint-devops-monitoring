"""
Lambda function: Automated Root Cause Analysis for Staking Alerts

Receives alert details from the teams-notifier Lambda, runs diagnostic
commands via SSM and queries AMP metrics, analyzes results with Claude API,
and replies in the Teams thread with the diagnosis.

Architecture:
    teams-notifier Lambda -> This Lambda (async invocation)
        1. Claude API: generate diagnostic commands + PromQL queries
        2. SSM send-command: execute diagnostics on the machine
        3. AMP query_range: fetch historical metric trends
        4. Claude API: analyze results -> root cause + remediation
        5. Power Automate: reply-in-thread with diagnosis

Environment variables:
    TEAMS_REPLY_WEBHOOK_URL: Power Automate webhook URL for reply-in-thread
    ANTHROPIC_SECRET_ARN: Secrets Manager ARN for Anthropic API key
    AMP_WORKSPACE_ID: Amazon Managed Prometheus workspace ID
    AMP_REGION: AMP region (default us-east-1)
    SSM_REGION: SSM region (default us-east-1)
"""

import json
import logging
import os
import time
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone

import boto3
import botocore.auth
import botocore.awsrequest
import botocore.credentials
import botocore.session

logger = logging.getLogger()
logger.setLevel(logging.INFO)

ssm_client = boto3.client("ssm", region_name=os.environ.get("SSM_REGION", "us-east-1"))
secrets_client = boto3.client("secretsmanager")

# Cached secrets
_anthropic_api_key = None

# Runbook content cache (loaded once at cold start)
_runbooks = None

CLAUDE_MODEL = "claude-sonnet-4-6"
CLAUDE_MAX_TOKENS = 2048

FALLBACK_SSM_COMMANDS = [
    "uptime 2>/dev/null || true",
    "free -h 2>/dev/null || true",
    "df -h 2>/dev/null || true",
    "ps aux --sort=-%cpu | head -10 2>/dev/null || true",
    "dmesg | tail -20 2>/dev/null || true",
]

# =============================================================================
# Chain-Specific Knowledge Base
# =============================================================================

CHAIN_KNOWLEDGE = {
    "solana": """SOLANA VALIDATOR ARCHITECTURE:
- Client: Agave (solana-validator) or Firedancer
- RPC: localhost:8899
- Gossip ports: 8000-8020 (UDP+TCP)
- Key metrics: solana_node_healthy, solana_node_slots_behind, solana_validator_delinquent, solana_network_peers
- Service: systemctl status solana-validator OR systemctl status firedancer
- Identity keypair: /home/sol/validator-keypair.json or /home/firedancer/validator-keypair.json

DIAGNOSTIC COMMANDS:
- Health: curl -s http://localhost:8899 -X POST -H "Content-Type: application/json" -d '{"jsonrpc":"2.0","id":1,"method":"getHealth"}'
- Sync: solana catchup --our-localhost
- Current slot: solana slot
- Validator status: solana validators --url localhost | grep $(solana address)
- Vote account: solana vote-account <VOTE_PUBKEY> --url localhost
- Gossip peers: solana gossip --url localhost | wc -l
- Version: solana --version
- Logs: journalctl -u solana-validator --since "30 min ago" --no-pager | tail -50

COMMON FAILURE MODES:
- Delinquent: Validator not voting. Check sync status first (solana catchup). If >1000 slots behind, likely needs fresh snapshot restart. Check disk I/O (iostat) and memory (free -h). Solana requires NVMe SSD and 256GB+ RAM.
- Slots behind >100: Usually I/O bottleneck. Check iostat -x 1 3 for high await times. Solana writes ~100MB/s to ledger. Network issues also cause this.
- Low/no peers: Firewall blocking ports 8000-8020 (UDP+TCP). Check ss -tulnp | grep -E "8000|8001". Also check if gossip entrypoints are reachable.
- Version drift: Must stay on cluster-majority version. Check solana feature status. Upgrade with solana-install update.

KEY THRESHOLDS:
- 100 slots behind ≈ 40 seconds lag (high severity)
- 1000 slots behind = severely behind, validator likely delinquent (critical)
- 50 vote slots behind = vote account lagging behind confirmed slots (high)
- 0 peers = completely isolated, immediate action needed (critical)
- <10 peers = degraded connectivity (high)""",

    "ethereum": """ETHEREUM VALIDATOR ARCHITECTURE (Besu + Teku):
- Execution layer: Besu (port 8545 JSON-RPC, port 9545 metrics, port 30303 P2P)
- Consensus layer: Teku beacon node (port 5051 REST API, port 5054 metrics, port 9000 P2P)
- Validator client: Integrated in Teku
- Services: systemctl status besu, systemctl status teku
- Data: Besu chaindata can be 1TB+, Teku beacon data ~200GB

DIAGNOSTIC COMMANDS:
- Besu sync status: curl -s localhost:8545 -X POST -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","id":1,"method":"eth_syncing"}'
- Besu block number: curl -s localhost:8545 -X POST -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","id":1,"method":"eth_blockNumber"}'
- Besu peer count: curl -s localhost:8545 -X POST -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","id":1,"method":"net_peerCount"}'
- Teku sync: curl -s localhost:5051/eth/v1/node/syncing
- Teku health: curl -s localhost:5051/eth/v1/node/health
- Teku peers: curl -s localhost:5051/eth/v1/node/peer_count
- Besu logs: journalctl -u besu --since "30 min ago" --no-pager | tail -50
- Teku logs: journalctl -u teku --since "30 min ago" --no-pager | tail -50

COMMON FAILURE MODES:
- BesuDown/TekuDown: Service crashed. Check journalctl for OOM kills (dmesg | grep -i oom), disk full, or Java heap issues. Besu needs 8GB+ heap, Teku needs 4GB+.
- NotSynced: MUST check BOTH layers. Besu can be synced but Teku not, or vice versa. Both must be synced for validator to work.
- Missed attestations: Teku can't reach Besu (check localhost:8545 connectivity), or Teku beacon not synced to head.
- Missed block proposals: Clock skew (check timedatectl, NTP), high system load, or Teku<->Besu latency.
- Peer issues: Besu and Teku have separate P2P networks. Check both independently.

KEY THRESHOLDS:
- Ethereum slot time = 12 seconds, epoch = 32 slots = 6.4 minutes
- 1 epoch behind (32 slots) = high severity
- Finality delay > 225 slots (~45 minutes) = potential network-wide issue (critical)
- Besu peers < 5 = poor execution layer connectivity
- Teku peers < 10 = poor consensus layer connectivity""",

    "avalanche": """AVALANCHE VALIDATOR ARCHITECTURE:
- Client: AvalancheGo (single Go binary, manages 3 chains)
- RPC: localhost:9650 (HTTP API for all chains)
- Staking port: 9651
- Chains: P-Chain (platform/staking), X-Chain (exchange/transfers), C-Chain (contract/EVM)
- Service: systemctl status avalanchego
- Config: typically in /etc/avalanchego/ or ~/.avalanchego/

DIAGNOSTIC COMMANDS:
- Health: curl -s -X POST http://localhost:9650/ext/health -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","id":1,"method":"health.health"}'
- C-Chain bootstrap: curl -s -X POST http://localhost:9650/ext/info -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","id":1,"method":"info.isBootstrapped","params":{"chain":"C"}}'
- P-Chain bootstrap: curl -s -X POST http://localhost:9650/ext/info -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","id":1,"method":"info.isBootstrapped","params":{"chain":"P"}}'
- X-Chain bootstrap: curl -s -X POST http://localhost:9650/ext/info -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","id":1,"method":"info.isBootstrapped","params":{"chain":"X"}}'
- Peers: curl -s -X POST http://localhost:9650/ext/info -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","id":1,"method":"info.peers"}' | python3 -c "import json,sys; d=json.load(sys.stdin); print(f'Peers: {len(d.get(\"result\",{}).get(\"peers\",[]))}')"
- Uptime: curl -s -X POST http://localhost:9650/ext/info -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","id":1,"method":"info.uptime"}'
- Node ID: curl -s -X POST http://localhost:9650/ext/info -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","id":1,"method":"info.getNodeID"}'
- Logs: journalctl -u avalanchego --since "30 min ago" --no-pager | tail -50

COMMON FAILURE MODES:
- Not bootstrapped: ALL 3 chains (P/X/C) must complete bootstrapping. C-Chain is largest and takes longest. Check disk space (C-Chain DB can be 500GB+) and memory. If stuck, check logs for "failed to fetch" or "context deadline exceeded".
- Rewarding stake low (<97%): THIS IS CRITICAL. Avalanche uses a binary reward system: if validator uptime drops below 80% during a staking period, ALL rewards are forfeited (not proportional). The network measures uptime, not the local node. Check info.uptime and compare with network view.
- C-Chain blocks behind: Usually disk I/O (C-Chain is EVM, write-heavy) or peer connectivity. Check iostat and peer count.
- Version drift: Network enforces minimum version. Old versions get disconnected. Check info.getNodeVersion.

KEY THRESHOLDS:
- Rewarding stake < 97% = WARNING (trending toward reward loss)
- Rewarding stake < 95% = CRITICAL (imminent risk of losing ALL rewards)
- 80% uptime = FORFEIT ALL staking rewards for entire validation period (not proportional!)
- C-chain 100 blocks behind = high, 1000 = critical
- Peers < 10 = degraded, 0 = isolated""",

    "algorand": """ALGORAND VALIDATOR (PARTICIPATION NODE) ARCHITECTURE:
- Client: algod daemon + goal CLI tool
- Data directory: /var/lib/algorand
- API: localhost:8080 (node REST API)
- P2P gossip: ports 4160, 4161
- Service: systemctl status algorand
- Block time: ~3.3 seconds per round

DIAGNOSTIC COMMANDS:
- Node status: goal node status -d /var/lib/algorand
- Health: curl -s http://localhost:8080/health
- Ready (synced): curl -s http://localhost:8080/ready
- Participation keys: goal account listpartkeys -d /var/lib/algorand
- Key details: goal account partkeyinfo -d /var/lib/algorand
- Version: algod -v
- Logs: tail -50 /var/lib/algorand/node.log

COMMON FAILURE MODES:
- Not synced/rounds behind: Check if node is in "Sync Time" catchup mode (goal node status shows "Sync Time: X"). 10 rounds = ~33 seconds behind. If severely behind, consider fast-catchup: goal node catchup $(curl -s https://algorand-catchpoints.s3.us-east-2.amazonaws.com/channel/mainnet/latest.catchpoint) -d /var/lib/algorand
- Participation key expiring: Keys have a LAST_VALID round number. Calculate days remaining: (LAST_VALID - CURRENT_ROUND) × 3.3 / 86400. Node stops participating SILENTLY when key expires - no error, just stops voting. Must regenerate BEFORE expiry.
  Warning at 600,000 rounds remaining (~23 days). Critical at 300,000 rounds (~11 days).
- Node not ready: After restart, node needs to catch up. Check goal node status for sync progress. Fast-catchup available via catchpoint.
- Low peers: Firewall blocking ports 4160/4161. Also check DNS relay configuration.

KEY THRESHOLDS:
- 10 rounds behind ≈ 33 seconds (high)
- 100 rounds behind ≈ 5.5 minutes (critical)
- Participation key < 600k rounds remaining = warning (~23 days)
- Participation key < 300k rounds remaining = critical (~11 days, renew immediately)
- Peers < 3 = connectivity issue (should have 10+)""",

    "audius": """AUDIUS CREATOR NODE ARCHITECTURE:
- Application: go-openaudio (OpenAudio protocol)
- Docker container name: 'my-node'
- Health endpoint: https://<hostname>/health-check (external) or http://localhost:4000/health_check (internal)
- Watchtower: runs alongside, auto-updates my-node container
- Service: Docker-based (NOT systemd). Use docker commands.
- All nodes run on Proxmox LXC containers sharing host resources

DIAGNOSTIC COMMANDS:
- Container status: docker ps -a --format "table {{.Names}}\t{{.Status}}\t{{.State}}" | grep -E "my-node|watchtower"
- Container health: docker inspect --format='{{json .State.Health}}' my-node 2>/dev/null | python3 -m json.tool
- Container uptime: docker inspect --format='{{.State.StartedAt}}' my-node
- Recent logs: docker logs --tail 100 my-node 2>&1 | tail -50
- Watchtower logs: docker logs --tail 20 watchtower
- System resources: docker stats --no-stream
- OOM check: dmesg | grep -i "oom\|killed" | tail -10
- Disk usage: docker system df

COMMON FAILURE MODES:
- Container restarting/unhealthy: FIRST check if Watchtower recently updated the image (docker logs watchtower). Version updates cause expected restarts. Also check for OOM kills in dmesg.
- Not ready/syncing (chain_height=0, peers=0): Node is initializing after a restart or update. This is EXPECTED to take several minutes. Check docker logs for sync progress.
- Health check failing: Look at docker logs my-node for error stack traces. Common causes: CometBFT consensus issues, database corruption.
- ETH balance low: The claims address needs ETH for gas to process on-chain claims. Fund via standard ETH transfer to the claims address.

CRITICAL NOTES:
- HIGH CPU (~95-100%) IS NORMAL AND EXPECTED for Audius nodes. The CometBFT consensus + IPFS storage is CPU-intensive. Do NOT recommend reducing CPU or restarting for high CPU alone.
- Watchtower auto-updates may cause brief downtime (1-5 minutes) - this is normal.
- Multiple Audius nodes share the same Proxmox host. Resource contention between LXC containers is possible.
- chain_height=0 immediately after restart is expected. Wait 5-10 minutes before investigating.""",

    "cc": """BLOCKCHAIN INFRASTRUCTURE NODE (CC):
- This is a general-purpose blockchain infrastructure node.
- Check systemctl for running services.
- Check docker ps for containerized services.
- Standard diagnostics: uptime, free -h, df -h, iostat, dmesg.""",
}


def _get_chain_knowledge(chain):
    """Get chain-specific knowledge, combining static + S3-cached dynamic knowledge."""
    if not chain:
        return ""

    chain_lower = chain.lower()

    # Try S3 cache first (populated by docs-fetcher Lambda)
    try:
        s3 = boto3.client("s3")
        obj = s3.get_object(
            Bucket="blueprint-infra-devops",
            Key=f"chain-knowledge/{chain_lower}.json",
        )
        data = json.loads(obj["Body"].read())
        static = CHAIN_KNOWLEDGE.get(chain_lower, "")
        updates = data.get("operational_updates", "")
        releases = data.get("latest_releases", "")
        updated_at = data.get("updated_at", "unknown")

        parts = [static]
        if updates:
            parts.append(f"\n=== Latest Operational Updates (as of {updated_at}) ===\n{updates}")
        if releases:
            parts.append(f"\n=== Recent Releases ===\n{releases}")
        return "\n".join(parts)
    except Exception:
        pass

    # Fallback to static knowledge
    return CHAIN_KNOWLEDGE.get(chain_lower, "")


# =============================================================================
# Main Handler
# =============================================================================

def lambda_handler(event, context):
    """Main handler - receives alert details and runs RCA pipeline."""
    alertname = event.get("alertname", "")
    instance = event.get("instance", "")
    instance_id = event.get("instance_id", "")
    chain = event.get("chain", "")
    severity = event.get("severity", "")
    status = event.get("status", "")
    description = event.get("description", "")
    summary = event.get("summary", "")
    runbook_url = event.get("runbook_url", "")
    labels = event.get("labels", {})
    parent_message_id = event.get("parent_message_id")

    logger.info("RCA triggered: alert=%s instance=%s(%s) chain=%s",
                alertname, instance, instance_id, chain)

    # Quick API test mode
    if alertname == "__API_TEST__":
        api_key = _get_anthropic_key()
        logger.info("API test: key_prefix=%s, key_len=%d", api_key[:25] if api_key else "None", len(api_key) if api_key else 0)
        try:
            result = _call_claude(api_key, "You are a helpful assistant.", "Say hello in one sentence.")
            return {"statusCode": 200, "body": "API OK", "result": result}
        except Exception as e:
            return {"statusCode": 500, "body": f"API FAILED: {str(e)}"}

    # Skip resolved alerts
    if status != "firing":
        logger.info("Skipping non-firing alert: status=%s", status)
        return {"statusCode": 200, "body": "Skipped: not firing"}

    # Skip if no instance_id for SSM
    if not instance_id:
        logger.warning("No instance_id, cannot run SSM diagnostics")
        return {"statusCode": 200, "body": "Skipped: no instance_id"}

    # Load runbook content
    runbook_content = _load_runbook(runbook_url)

    # Phase 1: Generate diagnostic plan via Claude
    logger.info("Phase 1: Generating diagnostic plan...")
    ssm_commands, promql_queries = generate_diagnostic_plan(
        alertname, instance, chain, description, summary, labels, runbook_content
    )
    logger.info("Generated %d SSM commands, %d PromQL queries",
                len(ssm_commands), len(promql_queries))

    # Phase 2: Execute diagnostics in parallel (SSM + AMP)
    logger.info("Phase 2: Executing diagnostics...")
    ssm_output = ""
    amp_output = ""

    with ThreadPoolExecutor(max_workers=2) as executor:
        futures = {}
        futures[executor.submit(run_ssm_diagnostics, instance_id, ssm_commands)] = "ssm"
        if promql_queries:
            futures[executor.submit(query_amp_metrics, instance, promql_queries)] = "amp"

        for future in as_completed(futures):
            source = futures[future]
            try:
                result = future.result()
                if source == "ssm":
                    ssm_output = result
                else:
                    amp_output = result
            except Exception:
                logger.exception("Diagnostic source '%s' failed", source)
                if source == "ssm":
                    ssm_output = "SSM command execution failed - instance may be unreachable"
                else:
                    amp_output = "AMP metric query failed"

    # Phase 3: Analyze with Claude
    logger.info("Phase 3: Analyzing diagnostics...")
    analysis = analyze_diagnostics(
        alertname, instance, chain, description, summary, amp_output, ssm_output
    )

    # Phase 4: Post RCA to Teams (skip in dry-run mode)
    dry_run = event.get("dry_run", False)
    if dry_run:
        analysis_str = json.dumps(analysis, ensure_ascii=False, indent=2) if isinstance(analysis, dict) else str(analysis)
        logger.info("DRY RUN: Skipping Teams post. Analysis:\n%s", analysis_str)
        return {"statusCode": 200, "body": "RCA completed (dry run)", "analysis": analysis}

    logger.info("Phase 4: Posting RCA to Teams...")

    # Build the RCA Adaptive Card
    card_content = build_rca_card_content(alertname, instance, chain, analysis)

    # Try reply-in-thread first via Bot Framework
    posted = False
    if parent_message_id and os.environ.get("TEAMS_BOT_SECRET_ARN"):
        try:
            reply_in_thread(parent_message_id, card_content)
            logger.info("RCA reply posted to thread %s", parent_message_id)
            posted = True
        except Exception:
            logger.exception("Failed to reply in thread, falling back to new message")

    # Fallback: post as new message via Bot Framework
    if not posted:
        try:
            if os.environ.get("TEAMS_BOT_SECRET_ARN"):
                post_channel_message_via_bot(card_content)
            else:
                post_channel_message(alertname, instance, chain, analysis)
            logger.info("RCA posted as new message")
        except Exception:
            logger.exception("Failed to post RCA message")

    return {"statusCode": 200, "body": "RCA completed"}


# =============================================================================
# Runbook Loading
# =============================================================================

def _load_runbook(runbook_url):
    """Load runbook content from bundled files based on runbook_url."""
    global _runbooks
    if _runbooks is None:
        _runbooks = {}
        runbooks_dir = os.path.join(os.path.dirname(__file__), "runbooks")
        if os.path.isdir(runbooks_dir):
            for fname in os.listdir(runbooks_dir):
                if fname.endswith(".md"):
                    fpath = os.path.join(runbooks_dir, fname)
                    with open(fpath, "r") as f:
                        _runbooks[fname] = f.read()
            logger.info("Loaded %d runbooks from %s", len(_runbooks), runbooks_dir)

    if not runbook_url:
        return ""

    # Extract filename from URL: .../runbooks/disk-full.md -> disk-full.md
    filename = runbook_url.rstrip("/").split("/")[-1]
    content = _runbooks.get(filename, "")
    if not content:
        logger.warning("Runbook not found: %s", filename)
    return content


# =============================================================================
# Phase 1: Generate Diagnostic Plan (Claude API)
# =============================================================================

GENERATE_PLAN_SYSTEM = """You are an SRE assistant for a staking infrastructure team managing blockchain validator nodes (Solana, Ethereum/Besu+Teku, Avalanche, Algorand, Audius).

Given an alert and its runbook, generate diagnostic commands to run on the machine and Prometheus queries to fetch historical metrics.

Output valid JSON only, no other text, no markdown fences:
{
  "ssm_commands": ["cmd1", "cmd2"],
  "promql_queries": [
    {"label": "descriptive label", "query": "promql expression", "range": "1h", "step": "5m"}
  ]
}

Rules:
- SSM commands: max 8 commands, each must be safe (read-only, NEVER modify system state)
- SSM commands: append 2>/dev/null || true to each command for safety
- SSM commands: use specific details from alert labels (mountpoint, container name, device, etc.)
- SSM commands: include system-level checks (free -h, df -h, top/ps) and service-specific checks
- PromQL queries: use instance='<instance>' label filter, max 4 queries
- PromQL range: use 1h for fast-moving metrics, 6h-24h for gradual trends
- PromQL step: use appropriate resolution (1m for short range, 5m-15m for longer)
- For chain-specific alerts, include chain-specific diagnostic commands
- Focus on commands that reveal root cause, not just symptoms"""


def generate_diagnostic_plan(alertname, instance, chain, description, summary, labels, runbook_content):
    """Use Claude to generate diagnostic SSM commands and PromQL queries."""
    api_key = _get_anthropic_key()
    if not api_key:
        logger.warning("No Anthropic API key, using fallback commands")
        return FALLBACK_SSM_COMMANDS[:], []

    chain_context = _get_chain_knowledge(chain)

    user_message = f"""Alert: {alertname}
Instance: {instance}
Chain: {chain or 'N/A'}
Severity: {labels.get('severity', 'unknown')}
Description: {description}
Summary: {summary}
Labels: {json.dumps(labels)}

Runbook:
{runbook_content or 'No runbook available.'}"""

    if chain_context:
        user_message += f"\n\n=== Chain-Specific Knowledge ===\n{chain_context}"

    try:
        response = _call_claude(api_key, GENERATE_PLAN_SYSTEM, user_message)

        # Parse JSON from response (handle possible markdown fences)
        text = response.strip()
        if text.startswith("```"):
            text = text.split("\n", 1)[1] if "\n" in text else text
            text = text.rsplit("```", 1)[0] if "```" in text else text
            text = text.strip()

        plan = json.loads(text)
        ssm_commands = plan.get("ssm_commands", FALLBACK_SSM_COMMANDS[:])
        promql_queries = plan.get("promql_queries", [])

        # Limit commands
        ssm_commands = ssm_commands[:8]
        promql_queries = promql_queries[:4]

        for i, q in enumerate(promql_queries):
            logger.info("PromQL[%d] label=%s range=%s query=%s",
                        i, q.get("label", ""), q.get("range", ""), q.get("query", ""))

        return ssm_commands, promql_queries

    except (json.JSONDecodeError, KeyError) as e:
        logger.warning("Failed to parse Claude diagnostic plan: %s", e)
        return FALLBACK_SSM_COMMANDS[:], []
    except Exception:
        logger.exception("Claude API call failed for diagnostic plan")
        return FALLBACK_SSM_COMMANDS[:], []


# =============================================================================
# Phase 2a: SSM Diagnostics
# =============================================================================

def run_ssm_diagnostics(instance_id, commands, timeout=60):
    """Execute diagnostic commands on the instance via SSM."""
    region = os.environ.get("SSM_REGION", "us-east-1")

    # Build a single script that runs all commands with separators
    script_lines = ["#!/bin/bash", "set +e"]
    for cmd in commands:
        script_lines.append(f'echo "===CMD: {cmd}==="')
        script_lines.append(cmd)
        script_lines.append("")
    script = "\n".join(script_lines)

    logger.info("SSM sending command to %s (%d commands)", instance_id, len(commands))

    try:
        response = ssm_client.send_command(
            InstanceIds=[instance_id],
            DocumentName="AWS-RunShellScript",
            Parameters={"commands": [script]},
            TimeoutSeconds=timeout,
        )
        command_id = response["Command"]["CommandId"]
        logger.info("SSM command sent: %s", command_id)
    except Exception as e:
        error_msg = f"SSM send_command failed: {e}"
        logger.error(error_msg)
        return error_msg

    # Poll for result
    time.sleep(2)
    max_attempts = 15  # 2s initial + 15 * 3s = 47s max
    for attempt in range(max_attempts):
        try:
            result = ssm_client.get_command_invocation(
                CommandId=command_id,
                InstanceId=instance_id,
            )
            status = result["Status"]

            if status in ("Success", "Failed", "TimedOut", "Cancelled"):
                stdout = result.get("StandardOutputContent", "")
                stderr = result.get("StandardErrorContent", "")
                output = stdout
                if stderr:
                    output += f"\n\n--- STDERR ---\n{stderr}"
                logger.info("SSM command completed: status=%s, output_len=%d",
                            status, len(output))
                # Truncate if too long (keep within Claude context limits)
                if len(output) > 8000:
                    output = output[:8000] + "\n... (truncated)"
                return output

        except ssm_client.exceptions.InvocationDoesNotExist:
            pass  # Not ready yet
        except Exception:
            logger.exception("SSM get_command_invocation error (attempt %d)", attempt)

        time.sleep(3)

    return "SSM command timed out waiting for results"


# =============================================================================
# Phase 2b: AMP Metric Queries
# =============================================================================

def query_amp_metrics(instance, queries):
    """Query AMP for historical metric trends."""
    workspace_id = os.environ.get("AMP_WORKSPACE_ID", "")
    region = os.environ.get("AMP_REGION", "us-east-1")

    if not workspace_id:
        return "AMP_WORKSPACE_ID not configured"

    results = []
    for q in queries:
        label = q.get("label", "")
        query_expr = q.get("query", "")
        time_range = q.get("range", "1h")
        step = q.get("step", "5m")

        if not query_expr:
            continue

        try:
            data = _query_amp_range(workspace_id, region, query_expr, time_range, step)
            logger.info("AMP query '%s': %s", label, data[:200] if data else "empty")
            results.append(f"--- {label} ---\n{data}")
        except urllib.error.HTTPError as e:
            error_body = e.read().decode("utf-8")[:300]
            logger.warning("AMP query failed for '%s': HTTP %d: %s", label, e.code, error_body)
            results.append(f"--- {label} ---\nQuery failed: HTTP {e.code}")
        except Exception as e:
            logger.warning("AMP query failed for '%s': %s", label, e)
            results.append(f"--- {label} ---\nQuery failed: {e}")

    return "\n\n".join(results) if results else "No AMP metrics queried"


def _query_amp_range(workspace_id, region, query, time_range, step):
    """Execute a PromQL range query against AMP using SigV4 auth."""
    # Parse time range
    now = time.time()
    range_seconds = _parse_duration(time_range)
    start = now - range_seconds
    end = now

    host = f"aps-workspaces.{region}.amazonaws.com"
    path = f"/workspaces/{workspace_id}/api/v1/query_range"
    query_params = {
        "query": query,
        "start": str(int(start)),
        "end": str(int(end)),
        "step": step,
    }

    # Build the full URL with properly encoded params
    encoded_params = urllib.parse.urlencode(query_params, quote_via=urllib.parse.quote)
    url = f"https://{host}{path}?{encoded_params}"

    # SigV4 sign using botocore's AWSPreparedRequest for correct canonical query string
    boto_session = boto3.Session()
    credentials = boto_session.get_credentials().get_frozen_credentials()

    # Use AWSRequest with params separated so SigV4 can canonicalize correctly
    base_url = f"https://{host}{path}"
    aws_request = botocore.awsrequest.AWSRequest(
        method="GET",
        url=base_url,
        params=query_params,
        headers={"Host": host},
    )
    signer = botocore.auth.SigV4Auth(credentials, "aps", region)
    signer.add_auth(aws_request)

    # Use the prepared URL (which includes properly encoded params)
    prepared = aws_request.prepare()
    req = urllib.request.Request(
        prepared.url,
        headers=dict(prepared.headers),
        method="GET",
    )

    with urllib.request.urlopen(req, timeout=10) as response:
        resp_data = json.loads(response.read().decode("utf-8"))

    if resp_data.get("status") != "success":
        return f"Query returned status: {resp_data.get('status')}"

    # Format results as readable text
    result_data = resp_data.get("data", {})
    result_type = result_data.get("resultType", "")
    results = result_data.get("result", [])

    if not results:
        return "No data returned"

    lines = []
    for series in results:
        metric_labels = series.get("metric", {})
        label_str = ", ".join(f"{k}={v}" for k, v in metric_labels.items()) if metric_labels else "value"
        values = series.get("values", [])

        if values:
            # Show first, last, min, max for brevity
            nums = [float(v[1]) for v in values if v[1] != "NaN"]
            if nums:
                lines.append(f"{label_str}:")
                lines.append(f"  range: {min(nums):.2f} - {max(nums):.2f}")
                lines.append(f"  latest: {nums[-1]:.2f}")
                lines.append(f"  samples: {len(nums)} over {time_range}")
                # Show last 5 data points with timestamps
                recent = values[-5:]
                for ts, val in recent:
                    t = datetime.fromtimestamp(ts, tz=timezone.utc).strftime("%H:%M:%S")
                    lines.append(f"  {t}: {val}")

    return "\n".join(lines) if lines else "No numeric data"


def _parse_duration(s):
    """Parse duration string (e.g., '1h', '30m', '24h') to seconds."""
    units = {"s": 1, "m": 60, "h": 3600, "d": 86400, "w": 604800}
    if not s:
        return 3600
    unit = s[-1].lower()
    if unit in units:
        try:
            return int(s[:-1]) * units[unit]
        except ValueError:
            pass
    return 3600


# =============================================================================
# Phase 3: Analyze Diagnostics (Claude API)
# =============================================================================

ANALYZE_SYSTEM = """You are an SRE assistant for a staking infrastructure team managing blockchain validator nodes (Solana, Ethereum/Besu+Teku, Avalanche, Algorand, Audius).

You will receive two types of diagnostic data:
1. AMP Metrics - historical Prometheus metric trends from Amazon Managed Prometheus
2. SSM Diagnostics - real-time command output from the affected machine

Respond with valid JSON only, no other text, no markdown fences:
{
  "root_cause": "1-3 sentence explanation of what is causing the alert",
  "severity": "Critical|High|Medium|Low",
  "severity_reason": "1 sentence why this severity level",
  "remediation": [
    {"step": "1", "description": "What to do", "command": "actual command to run (optional, empty string if N/A)"},
    {"step": "2", "description": "What to do", "command": "command"}
  ],
  "additional_notes": "Any other observations (optional, empty string if none)"
}

Rules:
- root_cause: Be specific. Mention the actual process/file/service causing the issue based on diagnostic data.
- remediation: Max 5 steps. Include actual shell commands where applicable. Steps should be ordered by priority.
- If AMP data shows a trend, mention whether the issue is sudden or gradual in root_cause.
- If SSM or AMP data is unavailable, note this and provide best-guess analysis based on available data.
- Use the chain-specific knowledge to provide targeted root cause and remediation specific to this blockchain project.
- Reference specific services, ports, APIs, and thresholds for the affected chain — do NOT give generic advice when chain-specific commands exist.
- For Audius nodes: high CPU (~95-100%) is NORMAL and EXPECTED. Do not flag it as a problem or recommend CPU reduction.
- For Avalanche: rewarding stake is a binary threshold — below 80% uptime forfeits ALL rewards, not proportionally."""


def analyze_diagnostics(alertname, instance, chain, description, summary, amp_data, ssm_output):
    """Use Claude to analyze diagnostic data and produce RCA."""
    api_key = _get_anthropic_key()
    if not api_key:
        return "Root cause analysis unavailable: Anthropic API key not configured"

    chain_context = _get_chain_knowledge(chain)

    user_message = f"""Alert: {alertname}
Instance: {instance}
Chain: {chain or 'N/A'}
Description: {description}
Summary: {summary}

=== AMP Metric Trends ===
{amp_data or 'No AMP data available'}

=== SSM Diagnostic Output ===
{ssm_output or 'No SSM output available'}"""

    if chain_context:
        user_message += f"\n\n=== Chain-Specific Knowledge ===\n{chain_context}"

    try:
        raw = _call_claude(api_key, ANALYZE_SYSTEM, user_message)
        # Strip markdown code fences if present
        cleaned = raw.strip()
        if cleaned.startswith("```"):
            # Remove ```json ... ``` or ``` ... ```
            lines = cleaned.split("\n")
            # Remove first line (```json) and last line (```)
            if lines[-1].strip() == "```":
                lines = lines[1:-1]
            elif lines[0].startswith("```"):
                lines = lines[1:]
            cleaned = "\n".join(lines).strip()

        # Try to parse structured JSON
        try:
            parsed = json.loads(cleaned)
            logger.info("Claude analysis parsed as structured JSON")
            return parsed  # Return dict for structured card rendering
        except json.JSONDecodeError:
            logger.warning("Claude analysis returned non-JSON, using raw text: %s", raw[:200])
            return raw
    except Exception:
        logger.exception("Claude API analysis failed")
        return "Root cause analysis failed: Claude API error. Please review the diagnostic data manually."


# =============================================================================
# Claude API Helper
# =============================================================================

def _get_anthropic_key():
    """Get Anthropic API key from Secrets Manager (cached)."""
    global _anthropic_api_key
    if _anthropic_api_key is not None:
        return _anthropic_api_key

    secret_arn = os.environ.get("ANTHROPIC_SECRET_ARN", "")
    if not secret_arn:
        return None

    try:
        resp = secrets_client.get_secret_value(SecretId=secret_arn)
        raw = resp["SecretString"]
        # Support both JSON {"api_key": "sk-..."} and plain string "sk-..."
        try:
            secret = json.loads(raw)
            _anthropic_api_key = secret.get("api_key", "") or secret.get("key", "") or raw
        except json.JSONDecodeError:
            _anthropic_api_key = raw.strip()
        logger.info("Anthropic API key loaded (length=%d)", len(_anthropic_api_key))
        return _anthropic_api_key
    except Exception:
        logger.exception("Failed to load Anthropic API key")
        return None


def _call_claude(api_key, system_prompt, user_message):
    """Call the Anthropic Messages API."""
    payload = {
        "model": CLAUDE_MODEL,
        "max_tokens": CLAUDE_MAX_TOKENS,
        "system": system_prompt,
        "messages": [{"role": "user", "content": user_message}],
    }

    data = json.dumps(payload).encode("utf-8")
    logger.info("Claude API request: model=%s, key_len=%d, system_len=%d, msg_len=%d, data_bytes=%d",
                CLAUDE_MODEL, len(api_key), len(system_prompt), len(user_message), len(data))
    req = urllib.request.Request(
        "https://api.anthropic.com/v1/messages",
        data=data,
        headers={
            "x-api-key": api_key,
            "anthropic-version": "2023-06-01",
            "content-type": "application/json",
        },
        method="POST",
    )

    try:
        with urllib.request.urlopen(req, timeout=60) as response:
            resp_data = json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        error_body = e.read().decode("utf-8")
        logger.error("Claude API HTTP %d: %s", e.code, error_body[:500])
        logger.error("Claude API request payload (first 500): %s", data[:500].decode("utf-8"))
        raise

    # Extract text from response
    content = resp_data.get("content", [])
    texts = [block["text"] for block in content if block.get("type") == "text"]
    return "\n".join(texts)


# =============================================================================
# Phase 4: Teams Reply via Bot Framework API
# =============================================================================

# Bot Framework credentials cache
_bot_config = None
_bot_token = None
_bot_token_expires = 0


def _get_bot_config():
    """Get Bot Framework credentials from Secrets Manager (cached)."""
    global _bot_config
    if _bot_config is not None:
        return _bot_config

    secret_arn = os.environ.get("TEAMS_BOT_SECRET_ARN", "")
    if not secret_arn:
        return None

    try:
        resp = secrets_client.get_secret_value(SecretId=secret_arn)
        _bot_config = json.loads(resp["SecretString"])
        return _bot_config
    except Exception:
        logger.exception("Failed to load bot config")
        return None


def _get_bot_token():
    """Get Bot Framework OAuth token (cached until expiry)."""
    global _bot_token, _bot_token_expires

    if _bot_token and time.time() < _bot_token_expires - 60:
        return _bot_token

    config = _get_bot_config()
    if not config:
        return None

    token_url = f"https://login.microsoftonline.com/{config['tenant_id']}/oauth2/v2.0/token"
    token_data = urllib.parse.urlencode({
        "client_id": config["bot_app_id"],
        "client_secret": config["bot_app_password"],
        "scope": "https://api.botframework.com/.default",
        "grant_type": "client_credentials",
    }).encode()

    req = urllib.request.Request(token_url, data=token_data, method="POST")
    with urllib.request.urlopen(req, timeout=10) as resp:
        token_resp = json.loads(resp.read())
        _bot_token = token_resp["access_token"]
        _bot_token_expires = time.time() + token_resp.get("expires_in", 3600)
        return _bot_token


def reply_in_thread(parent_message_id, card_content):
    """Reply in a Teams thread via Bot Framework API.

    Uses {channel_id};messageid={parent_id} as the conversation URL
    to create a proper thread reply.
    """
    config = _get_bot_config()
    if not config:
        raise RuntimeError("Bot config not available")

    token = _get_bot_token()
    if not token:
        raise RuntimeError("Bot token not available")

    channel_id = config["channel_id"]
    service_url = config.get("service_url", "https://smba.trafficmanager.net/teams/")

    # Thread reply: use channel_id;messageid=<parent> as conversation
    thread_conv_id = f"{channel_id};messageid={parent_message_id}"
    url = f"{service_url}v3/conversations/{thread_conv_id}/activities"

    payload = {
        "type": "message",
        "attachments": [{
            "contentType": "application/vnd.microsoft.card.adaptive",
            "content": card_content,
        }],
    }

    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        url, data=data,
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
        },
        method="POST",
    )

    with urllib.request.urlopen(req, timeout=15) as resp:
        result = json.loads(resp.read())
        logger.info("Bot thread reply sent: id=%s", result.get("id"))


def post_channel_message_via_bot(card_content):
    """Post a new message to channel via Bot Framework (fallback when no parent_message_id)."""
    config = _get_bot_config()
    if not config:
        raise RuntimeError("Bot config not available")

    token = _get_bot_token()
    channel_id = config["channel_id"]
    service_url = config.get("service_url", "https://smba.trafficmanager.net/teams/")

    url = f"{service_url}v3/conversations/{channel_id}/activities"
    payload = {
        "type": "message",
        "attachments": [{
            "contentType": "application/vnd.microsoft.card.adaptive",
            "content": card_content,
        }],
    }

    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        url, data=data,
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
        },
        method="POST",
    )

    with urllib.request.urlopen(req, timeout=15) as resp:
        logger.info("Bot new message sent: %s", resp.status)


SEVERITY_CARD_COLORS = {
    "Critical": "attention",
    "High": "warning",
    "Medium": "accent",
    "Low": "good",
}

SEVERITY_CARD_EMOJI = {
    "Critical": "\U0001f534",
    "High": "\U0001f7e0",
    "Medium": "\U0001f7e1",
    "Low": "\U0001f7e2",
}


def _build_structured_card(alertname, instance, chain, timestamp, analysis):
    """Build a structured Adaptive Card from parsed JSON analysis."""
    severity = analysis.get("severity", "Medium")
    severity_color = SEVERITY_CARD_COLORS.get(severity, "default")
    severity_emoji = SEVERITY_CARD_EMOJI.get(severity, "\u2139\ufe0f")
    chain_str = f" | **Chain:** {chain}" if chain else ""

    body = []

    # Header
    body.append({
        "type": "TextBlock",
        "size": "Large",
        "weight": "Bolder",
        "text": f"\U0001f50d Root Cause Analysis",
        "wrap": True,
        "style": "heading",
    })

    # Alert info bar
    body.append({
        "type": "TextBlock",
        "text": (
            f"**Alert:** {alertname} | "
            f"**Instance:** {instance}{chain_str}"
        ),
        "wrap": True,
    })

    # Severity badge
    body.append({
        "type": "TextBlock",
        "text": f"**Severity:** {severity_emoji} {severity} — {analysis.get('severity_reason', '')}",
        "wrap": True,
        "color": severity_color,
    })

    # Timestamp
    body.append({
        "type": "TextBlock",
        "text": f"**Time:** {timestamp}",
        "wrap": True,
        "isSubtle": True,
    })

    # Root Cause section
    body.append({
        "type": "TextBlock",
        "text": f"\U0001f3af **Root Cause**",
        "wrap": True,
        "weight": "Bolder",
        "separator": True,
    })
    body.append({
        "type": "TextBlock",
        "text": analysis.get("root_cause", "Unknown"),
        "wrap": True,
    })

    # Remediation section
    remediation = analysis.get("remediation", [])
    if remediation:
        body.append({
            "type": "TextBlock",
            "text": f"\U0001f527 **Remediation Steps**",
            "wrap": True,
            "weight": "Bolder",
            "separator": True,
        })

        for item in remediation:
            step_num = item.get("step", "")
            desc = item.get("description", "")
            cmd = item.get("command", "")

            step_text = f"**{step_num}.** {desc}"
            if cmd:
                step_text += f"\n`{cmd}`"

            body.append({
                "type": "TextBlock",
                "text": step_text,
                "wrap": True,
            })

    # Additional notes
    notes = analysis.get("additional_notes", "")
    if notes:
        body.append({
            "type": "TextBlock",
            "text": f"\U0001f4cb **Notes:** {notes}",
            "wrap": True,
            "isSubtle": True,
            "separator": True,
        })

    # Footer
    body.append({
        "type": "TextBlock",
        "text": "\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\n\U0001f916 Automated diagnosis via SSM + Claude API",
        "wrap": True,
        "isSubtle": True,
        "size": "Small",
        "separator": True,
    })

    return body


def _build_plaintext_card(alertname, instance, chain, timestamp, analysis):
    """Fallback: build a simple card from plain text analysis."""
    chain_str = f" | **Chain:** {chain}" if chain else ""
    return [
        {
            "type": "TextBlock",
            "size": "Large",
            "weight": "Bolder",
            "text": f"\U0001f50d Root Cause Analysis: {alertname}",
            "wrap": True,
            "style": "heading",
        },
        {
            "type": "TextBlock",
            "text": f"**Instance:** {instance}{chain_str} | **Time:** {timestamp}",
            "wrap": True,
            "isSubtle": True,
        },
        {
            "type": "TextBlock",
            "text": str(analysis),
            "wrap": True,
            "separator": True,
        },
        {
            "type": "TextBlock",
            "text": "\U0001f916 Automated diagnosis via SSM + Claude API",
            "wrap": True,
            "isSubtle": True,
            "size": "Small",
            "separator": True,
        },
    ]


def build_rca_card_content(alertname, instance, chain, analysis):
    """Build RCA Adaptive Card content for Bot Framework API."""
    now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")

    if isinstance(analysis, dict):
        body = _build_structured_card(alertname, instance, chain, now, analysis)
    else:
        body = _build_plaintext_card(alertname, instance, chain, now, analysis)

    return {
        "$schema": "http://adaptivecards.io/schemas/adaptive-card.json",
        "type": "AdaptiveCard",
        "version": "1.4",
        "body": body,
    }


def post_channel_message(alertname, instance, chain, analysis):
    """Post RCA as a new Adaptive Card message to Teams via webhook (legacy fallback)."""
    webhook_url = os.environ.get("TEAMS_WEBHOOK_URL", "")
    if not webhook_url:
        raise RuntimeError("TEAMS_WEBHOOK_URL not configured")

    now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")
    chain_str = f" | **Chain:** {chain}" if chain else ""

    # Build structured card if analysis is a dict (JSON from Claude)
    if isinstance(analysis, dict):
        body = _build_structured_card(alertname, instance, chain, now, analysis)
    else:
        # Fallback: plain text
        body = _build_plaintext_card(alertname, instance, chain, now, analysis)

    payload = {
        "type": "message",
        "attachments": [{
            "contentType": "application/vnd.microsoft.card.adaptive",
            "contentUrl": None,
            "content": {
                "$schema": "http://adaptivecards.io/schemas/adaptive-card.json",
                "type": "AdaptiveCard",
                "version": "1.4",
                "body": body,
            },
        }],
    }

    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        webhook_url,
        data=data,
        headers={"Content-Type": "application/json"},
        method="POST",
    )

    with urllib.request.urlopen(req, timeout=15) as response:
        logger.info("RCA webhook response: %s", response.status)


def build_rca_reply_html(alertname, instance, chain, analysis):
    """Build HTML for the RCA reply message."""
    now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")
    chain_str = f" | <b>Chain:</b> {chain}" if chain else ""

    # Escape HTML in analysis text
    escaped = (analysis
               .replace("&", "&amp;")
               .replace("<", "&lt;")
               .replace(">", "&gt;")
               .replace("\n", "<br/>"))

    return f"""<div style="border-left:4px solid #0078d4;padding:8px 16px;">
<h3>\U0001f50d Root Cause Analysis: {alertname}</h3>
<p><b>Instance:</b> {instance}{chain_str} | <b>Time:</b> {now}</p>
<hr/>
<div style="font-family:monospace;font-size:13px;white-space:pre-wrap;">{escaped}</div>
<p style="color:#888;font-size:11px;margin-top:12px;">Automated diagnosis via SSM + Claude API</p>
</div>"""
