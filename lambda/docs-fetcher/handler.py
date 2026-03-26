"""
Lambda function: Chain Knowledge Fetcher

Periodically fetches the latest release notes and operational documentation
from each blockchain project's GitHub repos and official docs, then uses
Claude to extract actionable operational knowledge for node operators.

Results are stored in S3 for the RCA Lambda to consume at cold start.

Architecture:
    EventBridge (weekly cron) -> This Lambda
        -> GitHub API: fetch latest releases
        -> Official docs: fetch troubleshooting pages
        -> Claude API: summarize into operational knowledge
        -> S3: store as chain-knowledge/{chain}.json

Environment variables:
    ANTHROPIC_SECRET_ARN: Secrets Manager ARN for Anthropic API key
    S3_BUCKET: S3 bucket for storing chain knowledge (default: blueprint-infra-devops)
"""

import json
import logging
import os
import urllib.error
import urllib.request
from datetime import datetime, timezone

import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

secrets_client = boto3.client("secretsmanager")
s3_client = boto3.client("s3")

_anthropic_api_key = None

S3_BUCKET = os.environ.get("S3_BUCKET", "blueprint-infra-devops")
S3_PREFIX = "chain-knowledge"

CLAUDE_MODEL = "claude-sonnet-4-6"

# Notion integration
_notion_token = None
NOTION_CHAIN_PAGES = {
    "solana": "32f09a37-0ee0-81f6-85a6-ea797c34e9fe",
    "ethereum": "32f09a37-0ee0-81ab-bb69-ec252276c988",
    "avalanche": "32f09a37-0ee0-8146-80fd-c77d94fcc1cb",
    "algorand": "32f09a37-0ee0-81f8-9b28-c2db2d280999",
    "audius": "32f09a37-0ee0-8166-9f38-edbff0b15df1",
}

# =============================================================================
# Chain Data Sources
# =============================================================================

CHAIN_SOURCES = {
    "solana": {
        "github_repos": [
            "anza-xyz/agave",
            "firedancer-io/firedancer",
        ],
        "docs_urls": [
            "https://docs.solanalabs.com/operations/best-practices/general",
            "https://docs.solanalabs.com/operations/guides/validator-start",
        ],
    },
    "ethereum": {
        "github_repos": [
            "hyperledger/besu",
            "Consensys/teku",
        ],
        "docs_urls": [
            "https://besu.hyperledger.org/stable/public-networks/how-to/troubleshoot/performance",
            "https://docs.teku.consensys.io/how-to/troubleshoot/general",
        ],
    },
    "avalanche": {
        "github_repos": [
            "ava-labs/avalanchego",
        ],
        "docs_urls": [
            "https://docs.avax.network/nodes/maintain/node-backup-and-restore",
            "https://docs.avax.network/nodes/maintain/upgrade-your-avalanchego-node",
        ],
    },
    "algorand": {
        "github_repos": [
            "algorand/go-algorand",
        ],
        "docs_urls": [
            "https://developer.algorand.org/docs/run-a-node/operations/switch_networks/",
        ],
    },
    "audius": {
        "github_repos": [
            "AudiusProject/audius-protocol",
            "OpenAudio/go-openaudio",
        ],
        "docs_urls": [],
    },
}

SUMMARIZE_SYSTEM = """You are an SRE assistant specializing in blockchain validator node operations.

Given release notes and documentation for a blockchain project, extract actionable operational knowledge for node operators.

Focus on:
1. BREAKING CHANGES that affect node operation (config changes, API changes, port changes)
2. KNOWN ISSUES and their workarounds
3. NEW DIAGNOSTIC COMMANDS or tools added in recent versions
4. UPDATED THRESHOLDS or performance recommendations
5. DEPRECATIONS that operators should prepare for
6. SECURITY ADVISORIES requiring immediate action

Output format - concise bullet points grouped by category:

BREAKING CHANGES:
- ...

KNOWN ISSUES:
- ...

NEW FEATURES FOR OPERATORS:
- ...

RECOMMENDED ACTIONS:
- ...

If there's nothing notable, say "No significant operational changes in recent releases."
Keep response under 500 words. Be specific — include version numbers, config keys, command names."""


# Static operational knowledge per chain (also used by rca-analyzer)
STATIC_OPS_KNOWLEDGE = {
    "solana": {
        "title": "Solana Validator",
        "clients": "Agave (solana-validator) / Firedancer",
        "architecture": [
            "RPC endpoint: localhost:8899 (JSON-RPC)",
            "Gossip ports: 8000-8020 (UDP+TCP)",
            "Identity keypair: /home/sol/validator-keypair.json or /home/firedancer/validator-keypair.json",
            "Service: systemctl status solana-validator OR systemctl status firedancer",
            "Ledger: /data/solana/ledger (requires NVMe SSD, 256GB+ RAM)",
        ],
        "health_checks": [
            ("Node health", "curl -s http://localhost:8899 -X POST -H 'Content-Type: application/json' -d '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"getHealth\"}'"),
            ("Sync status", "solana catchup --our-localhost"),
            ("Current slot", "solana slot"),
            ("Validator status", "solana validators --url localhost | grep $(solana address)"),
            ("Vote account", "solana vote-account <VOTE_PUBKEY> --url localhost"),
            ("Peer count", "solana gossip --url localhost | wc -l"),
            ("Version", "solana --version"),
            ("Service logs", "journalctl -u solana-validator --since '30 min ago' --no-pager | tail -50"),
        ],
        "alert_thresholds": [
            "slots_behind > 100 ≈ 40s lag → HIGH",
            "slots_behind > 1000 = severely behind, validator likely delinquent → CRITICAL",
            "vote_slots_behind > 50 = vote account lagging → HIGH",
            "peers == 0 = isolated → CRITICAL",
            "peers < 10 = degraded → HIGH",
        ],
        "common_issues": [
            ("Validator delinquent", "Not voting. Run `solana catchup --our-localhost`. If >1000 slots behind, restart with fresh snapshot. Check disk I/O (`iostat -x 1 3`) and memory (`free -h`)."),
            ("Slots behind >100", "Usually I/O bottleneck. Solana requires NVMe SSD with high IOPS. Check `iostat` for high await times. Also check network connectivity."),
            ("Low/no peers", "Check firewall: ports 8000-8020 (UDP+TCP) must be open. Verify gossip entrypoints are reachable."),
            ("Version drift", "Must stay on cluster-majority version. Check `solana feature status`. Upgrade: `solana-install update`"),
            ("High memory usage", "Normal — Solana validators use 256GB+ RAM. Only investigate if OOM kills occur (`dmesg | grep -i oom`)."),
            ("Snapshot restart", "solana-validator exit --force && restart service. May need to download fresh snapshot if severely behind."),
        ],
        "version_upgrade": "solana-install update (Agave) / Follow Firedancer release notes for fdctl upgrade",
        "restart_procedure": "systemctl restart solana-validator (graceful). For stuck nodes: solana-validator exit --force",
    },
    "ethereum": {
        "title": "Ethereum Validator (Besu + Teku)",
        "clients": "Besu (execution layer) + Teku (consensus + validator)",
        "architecture": [
            "Besu: port 8545 (JSON-RPC), 9545 (metrics), 30303 (P2P)",
            "Teku: port 5051 (REST API), 5054 (metrics), 9000 (P2P)",
            "Validator client: integrated in Teku",
            "Services: systemctl status besu, systemctl status teku",
            "Data: Besu chaindata ~1TB+, Teku beacon ~200GB",
        ],
        "health_checks": [
            ("Besu sync", "curl -s localhost:8545 -X POST -H 'Content-Type: application/json' -d '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_syncing\"}'"),
            ("Besu block number", "curl -s localhost:8545 -X POST -H 'Content-Type: application/json' -d '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_blockNumber\"}'"),
            ("Besu peers", "curl -s localhost:8545 -X POST -H 'Content-Type: application/json' -d '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"net_peerCount\"}'"),
            ("Teku sync", "curl -s localhost:5051/eth/v1/node/syncing"),
            ("Teku health", "curl -s localhost:5051/eth/v1/node/health"),
            ("Teku peers", "curl -s localhost:5051/eth/v1/node/peer_count"),
            ("Besu logs", "journalctl -u besu --since '30 min ago' --no-pager | tail -50"),
            ("Teku logs", "journalctl -u teku --since '30 min ago' --no-pager | tail -50"),
        ],
        "alert_thresholds": [
            "Slot time = 12s, epoch = 32 slots = 6.4 minutes",
            "1 epoch behind (32 slots) → HIGH",
            "Finality delay > 225 slots (~45 min) → CRITICAL (possible network issue)",
            "Besu peers < 5 → degraded execution layer",
            "Teku peers < 10 → degraded consensus layer",
        ],
        "common_issues": [
            ("Besu/Teku down", "Check journalctl for OOM kills, disk full, Java heap issues. Besu needs 8GB+ heap, Teku 4GB+. Check `dmesg | grep -i oom`."),
            ("Not synced", "MUST check BOTH layers. Besu can be synced but Teku not, or vice versa. Both must be synced for validator duties."),
            ("Missed attestations", "Teku can't reach Besu (check localhost:8545), or Teku beacon not synced to chain head."),
            ("Missed block proposals", "Check clock sync (`timedatectl`), NTP drift, system load, Teku<->Besu latency."),
            ("Peer issues", "Besu and Teku have SEPARATE P2P networks. Check both independently. Verify ports 30303 (Besu) and 9000 (Teku) are open."),
        ],
        "version_upgrade": "Stop teku → stop besu → upgrade binaries → start besu → wait for sync → start teku",
        "restart_procedure": "systemctl restart besu && sleep 30 && systemctl restart teku (always restart Besu first, wait for it to be ready)",
    },
    "avalanche": {
        "title": "Avalanche Validator",
        "clients": "AvalancheGo",
        "architecture": [
            "Single Go binary managing 3 chains: P-Chain, X-Chain, C-Chain",
            "RPC: localhost:9650 (HTTP API for all chains)",
            "Staking port: 9651",
            "Service: systemctl status avalanchego",
            "Config: /etc/avalanchego/ or ~/.avalanchego/",
            "C-Chain DB can grow to 500GB+",
        ],
        "health_checks": [
            ("Node health", "curl -s -X POST http://localhost:9650/ext/health -H 'Content-Type: application/json' -d '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"health.health\"}'"),
            ("C-Chain bootstrap", "curl -s -X POST http://localhost:9650/ext/info -H 'Content-Type: application/json' -d '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"info.isBootstrapped\",\"params\":{\"chain\":\"C\"}}'"),
            ("P-Chain bootstrap", "curl -s -X POST http://localhost:9650/ext/info -H 'Content-Type: application/json' -d '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"info.isBootstrapped\",\"params\":{\"chain\":\"P\"}}'"),
            ("X-Chain bootstrap", "curl -s -X POST http://localhost:9650/ext/info -H 'Content-Type: application/json' -d '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"info.isBootstrapped\",\"params\":{\"chain\":\"X\"}}'"),
            ("Peer count", "curl -s -X POST http://localhost:9650/ext/info -H 'Content-Type: application/json' -d '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"info.peers\"}' | python3 -c \"import json,sys; print(len(json.load(sys.stdin)['result']['peers']))\""),
            ("Uptime", "curl -s -X POST http://localhost:9650/ext/info -H 'Content-Type: application/json' -d '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"info.uptime\"}'"),
            ("Node ID", "curl -s -X POST http://localhost:9650/ext/info -H 'Content-Type: application/json' -d '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"info.getNodeID\"}'"),
            ("Logs", "journalctl -u avalanchego --since '30 min ago' --no-pager | tail -50"),
        ],
        "alert_thresholds": [
            "Rewarding stake < 97% → WARNING",
            "Rewarding stake < 95% → CRITICAL",
            "80% uptime = FORFEIT ALL staking rewards (binary, not proportional!)",
            "C-chain 100 blocks behind → HIGH",
            "C-chain 1000 blocks behind → CRITICAL",
            "Peers < 10 → degraded, 0 → isolated",
        ],
        "common_issues": [
            ("Not bootstrapped", "ALL 3 chains (P/X/C) must bootstrap. C-Chain is largest and slowest. Check disk space and memory. If stuck, check logs for 'failed to fetch' or 'context deadline exceeded'."),
            ("Rewarding stake low", "CRITICAL: Avalanche uses BINARY rewards — below 80% uptime forfeits ALL rewards, not proportional. Check `info.uptime`. Compare local vs network-observed uptime. Recent restarts or connectivity issues reduce uptime."),
            ("C-Chain blocks behind", "Usually disk I/O (C-Chain is EVM, write-heavy). Check `iostat`. Also check peer count."),
            ("Version drift", "Network enforces minimum version. Old versions get disconnected. Upgrade promptly after releases."),
        ],
        "version_upgrade": "systemctl stop avalanchego → download new binary → systemctl start avalanchego",
        "restart_procedure": "systemctl restart avalanchego (node will re-bootstrap, may take minutes to hours depending on chain state)",
    },
    "algorand": {
        "title": "Algorand Participation Node",
        "clients": "algod + goal CLI",
        "architecture": [
            "Data directory: /var/lib/algorand",
            "API: localhost:8080 (node REST API)",
            "P2P gossip: ports 4160, 4161",
            "Service: systemctl status algorand",
            "Block time: ~3.3 seconds per round",
        ],
        "health_checks": [
            ("Node status", "goal node status -d /var/lib/algorand"),
            ("Health", "curl -s http://localhost:8080/health"),
            ("Ready (synced)", "curl -s http://localhost:8080/ready"),
            ("Participation keys", "goal account listpartkeys -d /var/lib/algorand"),
            ("Key details", "goal account partkeyinfo -d /var/lib/algorand"),
            ("Version", "algod -v"),
            ("Logs", "tail -50 /var/lib/algorand/node.log"),
        ],
        "alert_thresholds": [
            "10 rounds behind ≈ 33 seconds → HIGH",
            "100 rounds behind ≈ 5.5 minutes → CRITICAL",
            "Participation key < 600k rounds remaining (~23 days) → WARNING",
            "Participation key < 300k rounds remaining (~11 days) → CRITICAL (renew immediately)",
            "Peers < 3 → connectivity issue",
        ],
        "common_issues": [
            ("Rounds behind / not synced", "Check `goal node status` for sync progress. If severely behind, use fast-catchup: `goal node catchup $(curl -s https://algorand-catchpoints.s3.us-east-2.amazonaws.com/channel/mainnet/latest.catchpoint) -d /var/lib/algorand`"),
            ("Participation key expiring", "Keys expire SILENTLY. Days remaining = (LAST_VALID - CURRENT_ROUND) × 3.3 / 86400. Must regenerate BEFORE expiry. Run `goal account partkeyinfo -d /var/lib/algorand` to check."),
            ("Node not ready after restart", "Normal catchup behavior. Check `goal node status` for sync time. Fast-catchup available via catchpoint."),
            ("Low peers", "Check firewall for ports 4160/4161. Check DNS relay configuration."),
        ],
        "version_upgrade": "systemctl stop algorand → update algod binary → systemctl start algorand. Use `goal node status` to verify sync after restart.",
        "restart_procedure": "systemctl restart algorand. Node will catch up automatically.",
    },
    "audius": {
        "title": "Audius Creator Node",
        "clients": "go-openaudio (Docker container 'my-node')",
        "architecture": [
            "Docker container: 'my-node' (Audius creator node)",
            "Health: https://<hostname>/health-check (external), http://localhost:4000/health_check (internal)",
            "Watchtower: auto-updates my-node container",
            "All nodes run on Proxmox LXC containers sharing host resources",
            "CPU at ~100% is NORMAL — CometBFT consensus + IPFS is CPU-intensive",
        ],
        "health_checks": [
            ("Container status", "docker ps -a --format 'table {{.Names}}\\t{{.Status}}\\t{{.State}}' | grep -E 'my-node|watchtower'"),
            ("Container health", "docker inspect --format='{{json .State.Health}}' my-node 2>/dev/null | python3 -m json.tool"),
            ("Container uptime", "docker inspect --format='{{.State.StartedAt}}' my-node"),
            ("Recent logs", "docker logs --tail 100 my-node 2>&1 | tail -50"),
            ("Watchtower logs", "docker logs --tail 20 watchtower"),
            ("Resource usage", "docker stats --no-stream"),
            ("OOM check", "dmesg | grep -i 'oom\\|killed' | tail -10"),
            ("Disk usage", "docker system df"),
        ],
        "alert_thresholds": [
            "CPU ~95-100% = NORMAL (do NOT alert)",
            "chain_height = 0 after restart = NORMAL (wait 5-10 min)",
            "ETH balance < 0.1 ETH → WARNING",
            "ETH balance < 0.04 ETH → CRITICAL (claims may fail)",
        ],
        "common_issues": [
            ("Container restarting", "Check Watchtower logs first — version update causes expected restart. Check `dmesg` for OOM kills. DO NOT assume high CPU is the cause."),
            ("Not ready / syncing / chain_height=0", "Node initializing after restart. Expected to take 5-10 minutes. Check `docker logs my-node` for sync progress."),
            ("Health check failing", "Check `docker logs my-node` for error stack traces. Common: CometBFT consensus issues, database corruption."),
            ("ETH balance low", "Fund the claims address via standard ETH transfer."),
            ("High CPU", "NORMAL AND EXPECTED. Do NOT restart, reduce CPU, or investigate unless other symptoms exist."),
        ],
        "version_upgrade": "Watchtower handles automatic updates. For manual: docker pull <image> && docker restart my-node",
        "restart_procedure": "docker restart my-node. Wait 5-10 minutes for sync.",
    },
}


# =============================================================================
# Main Handler
# =============================================================================

def lambda_handler(event, context):
    """Fetch latest chain knowledge and store in S3."""
    api_key = _get_anthropic_key()
    if not api_key:
        logger.error("No Anthropic API key available")
        return {"statusCode": 500, "body": "No API key"}

    results = {}
    for chain, sources in CHAIN_SOURCES.items():
        logger.info("Processing chain: %s", chain)

        try:
            # Fetch GitHub releases
            releases_text = ""
            for repo in sources["github_repos"]:
                releases = fetch_github_releases(repo, count=3)
                if releases:
                    releases_text += f"\n--- {repo} ---\n{releases}\n"

            # Fetch documentation pages
            docs_text = ""
            for url in sources["docs_urls"]:
                doc = fetch_url_content(url)
                if doc:
                    docs_text += f"\n--- {url} ---\n{doc[:3000]}\n"

            # Summarize with Claude
            if releases_text or docs_text:
                knowledge = summarize_with_claude(api_key, chain, releases_text, docs_text)
            else:
                knowledge = "No data fetched from sources."

            # Store in S3
            s3_data = {
                "chain": chain,
                "updated_at": datetime.now(timezone.utc).isoformat(),
                "operational_updates": knowledge,
                "latest_releases": releases_text[:2000] if releases_text else "",
                "sources": {
                    "github_repos": sources["github_repos"],
                    "docs_urls": sources["docs_urls"],
                },
            }

            s3_key = f"{S3_PREFIX}/{chain}.json"
            s3_client.put_object(
                Bucket=S3_BUCKET,
                Key=s3_key,
                Body=json.dumps(s3_data, ensure_ascii=False, indent=2),
                ContentType="application/json",
            )
            logger.info("Stored %s knowledge in s3://%s/%s", chain, S3_BUCKET, s3_key)

            # Also update Notion page
            try:
                update_notion_page(chain, knowledge, releases_text)
                logger.info("Updated Notion page for %s", chain)
            except Exception:
                logger.exception("Failed to update Notion for %s (non-fatal)", chain)

            results[chain] = "ok"

        except Exception:
            logger.exception("Failed to process chain: %s", chain)
            results[chain] = "error"

    return {"statusCode": 200, "body": json.dumps(results)}


# =============================================================================
# GitHub API
# =============================================================================

def fetch_github_releases(repo, count=3):
    """Fetch the latest releases from a GitHub repo."""
    url = f"https://api.github.com/repos/{repo}/releases?per_page={count}"
    req = urllib.request.Request(
        url,
        headers={
            "Accept": "application/vnd.github+json",
            "User-Agent": "staking-alert-docs-fetcher",
        },
    )

    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            releases = json.loads(resp.read())
    except Exception as e:
        logger.warning("Failed to fetch releases for %s: %s", repo, e)
        return ""

    lines = []
    for rel in releases[:count]:
        tag = rel.get("tag_name", "")
        name = rel.get("name", tag)
        date = rel.get("published_at", "")[:10]
        body = rel.get("body", "")[:1500]
        lines.append(f"Release: {name} ({tag}) - {date}\n{body}\n")

    return "\n".join(lines)


def fetch_url_content(url):
    """Fetch a URL and return text content (strip HTML tags)."""
    req = urllib.request.Request(
        url,
        headers={"User-Agent": "staking-alert-docs-fetcher"},
    )

    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            content = resp.read().decode("utf-8", errors="replace")
    except Exception as e:
        logger.warning("Failed to fetch %s: %s", url, e)
        return ""

    # Simple HTML tag stripping
    import re
    text = re.sub(r"<script[^>]*>.*?</script>", "", content, flags=re.DOTALL)
    text = re.sub(r"<style[^>]*>.*?</style>", "", text, flags=re.DOTALL)
    text = re.sub(r"<[^>]+>", " ", text)
    text = re.sub(r"\s+", " ", text).strip()
    return text[:5000]


# =============================================================================
# Claude API
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
        try:
            secret = json.loads(raw)
            _anthropic_api_key = secret.get("api_key", "") or secret.get("key", "") or raw
        except json.JSONDecodeError:
            _anthropic_api_key = raw.strip()
        return _anthropic_api_key
    except Exception:
        logger.exception("Failed to get Anthropic API key")
        return None


def summarize_with_claude(api_key, chain, releases_text, docs_text):
    """Use Claude to extract operational knowledge from releases and docs."""
    user_message = f"""Chain: {chain}

=== Recent GitHub Releases ===
{releases_text or 'No release data available.'}

=== Documentation ===
{docs_text or 'No documentation fetched.'}"""

    payload = {
        "model": CLAUDE_MODEL,
        "max_tokens": 1024,
        "system": SUMMARIZE_SYSTEM,
        "messages": [{"role": "user", "content": user_message}],
    }

    data = json.dumps(payload).encode("utf-8")
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
        return f"Claude summarization failed: HTTP {e.code}"

    content = resp_data.get("content", [])
    texts = [block["text"] for block in content if block.get("type") == "text"]
    return "\n".join(texts)


# =============================================================================
# Notion Integration
# =============================================================================

def _get_notion_token():
    """Get Notion API token from Secrets Manager (cached)."""
    global _notion_token
    if _notion_token is not None:
        return _notion_token

    secret_arn = os.environ.get("NOTION_SECRET_ARN", "")
    if not secret_arn:
        return None

    try:
        resp = secrets_client.get_secret_value(SecretId=secret_arn)
        raw = resp["SecretString"]
        try:
            secret = json.loads(raw)
            _notion_token = secret.get("token", "") or secret.get("notion_token", "") or raw
        except json.JSONDecodeError:
            _notion_token = raw.strip()
        return _notion_token
    except Exception:
        logger.exception("Failed to get Notion token")
        return None


def update_notion_page(chain, knowledge, releases_text):
    """Update the Notion page for a chain with a complete ops manual."""
    token = _get_notion_token()
    if not token:
        logger.warning("No Notion token, skipping Notion update")
        return

    page_id = NOTION_CHAIN_PAGES.get(chain)
    if not page_id:
        logger.warning("No Notion page ID for chain: %s", chain)
        return

    ops = STATIC_OPS_KNOWLEDGE.get(chain)
    if not ops:
        logger.warning("No static ops knowledge for chain: %s", chain)
        return

    now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")

    # Clear existing content blocks
    _notion_clear_blocks(token, page_id)

    blocks = []

    # Header
    blocks.append(_notion_callout(
        f"{ops['title']} — Operations Manual\nClients: {ops['clients']}\nLast updated: {now}",
        "📋"
    ))

    # === Architecture ===
    blocks.append(_notion_heading("Architecture"))
    for item in ops["architecture"]:
        blocks.append(_notion_bullet(item))

    blocks.append(_notion_divider())

    # === Health Checks ===
    blocks.append(_notion_heading("Health Checks"))
    health_code = "\n".join([f"# {label}\n{cmd}\n" for label, cmd in ops["health_checks"]])
    blocks.append(_notion_code(health_code))

    blocks.append(_notion_divider())

    # === Alert Thresholds ===
    blocks.append(_notion_heading("Alert Thresholds"))
    for item in ops["alert_thresholds"]:
        blocks.append(_notion_bullet(item))

    blocks.append(_notion_divider())

    # === Common Issues & Troubleshooting ===
    blocks.append(_notion_heading("Common Issues & Troubleshooting"))
    for issue, resolution in ops["common_issues"]:
        blocks.append(_notion_heading(f"🔧 {issue}", level=3))
        blocks.append(_notion_paragraph(resolution))

    blocks.append(_notion_divider())

    # === Operations ===
    blocks.append(_notion_heading("Operations"))
    blocks.append(_notion_heading("Version Upgrade", level=3))
    blocks.append(_notion_paragraph(ops["version_upgrade"]))
    blocks.append(_notion_heading("Restart Procedure", level=3))
    blocks.append(_notion_paragraph(ops["restart_procedure"]))

    blocks.append(_notion_divider())

    # === Latest Updates (from docs-fetcher) ===
    blocks.append(_notion_heading("Latest Updates (Auto-fetched)"))
    if knowledge:
        for line in knowledge.split("\n"):
            line = line.strip()
            if not line or line == "---":
                continue
            # Strip markdown heading syntax
            if line.startswith("#"):
                text = line.lstrip("# ").strip()
                blocks.append(_notion_heading(text, level=3))
            # Section headers like "BREAKING CHANGES:" or "KNOWN ISSUES:"
            elif line.endswith(":") and line.replace(" ", "").replace("_", "").rstrip(":").isupper():
                blocks.append(_notion_heading(line.rstrip(":"), level=3))
            elif line.startswith("- "):
                # Convert **bold** markdown to Notion rich_text bold
                blocks.append(_notion_bullet_rich(line[2:]))
            else:
                blocks.append(_notion_paragraph_rich(line))
    else:
        blocks.append(_notion_paragraph("No updates available."))

    blocks.append(_notion_divider())

    # === Release Notes Summary ===
    blocks.append(_notion_heading("Recent Release Notes"))
    if releases_text:
        # Summarize: just show release headers
        for line in releases_text[:3000].split("\n"):
            line = line.strip()
            if not line:
                continue
            if line.startswith("Release:"):
                blocks.append(_notion_bullet(line))
    else:
        blocks.append(_notion_paragraph("No release data available."))

    # Notion API limits: max 100 blocks per request
    for i in range(0, len(blocks), 100):
        chunk = blocks[i:i + 100]
        _notion_append_blocks(token, page_id, chunk)


def _notion_clear_blocks(token, page_id):
    """Delete all child blocks from a Notion page."""
    url = f"https://api.notion.com/v1/blocks/{page_id}/children?page_size=100"
    req = urllib.request.Request(url, headers={
        "Authorization": f"Bearer {token}",
        "Notion-Version": "2022-06-28",
    })

    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            data = json.loads(resp.read())
    except Exception:
        return

    for block in data.get("results", []):
        block_id = block["id"]
        del_req = urllib.request.Request(
            f"https://api.notion.com/v1/blocks/{block_id}",
            headers={
                "Authorization": f"Bearer {token}",
                "Notion-Version": "2022-06-28",
            },
            method="DELETE",
        )
        try:
            urllib.request.urlopen(del_req, timeout=10)
        except Exception:
            pass


def _notion_append_blocks(token, page_id, blocks):
    """Append blocks to a Notion page."""
    data = json.dumps({"children": blocks}).encode("utf-8")
    req = urllib.request.Request(
        f"https://api.notion.com/v1/blocks/{page_id}/children",
        data=data,
        headers={
            "Authorization": f"Bearer {token}",
            "Notion-Version": "2022-06-28",
            "Content-Type": "application/json",
        },
        method="PATCH",
    )
    with urllib.request.urlopen(req, timeout=15) as resp:
        resp.read()


def _notion_heading(text, level=2):
    key = f"heading_{level}"
    return {"object": "block", "type": key, key: {
        "rich_text": [{"text": {"content": text[:2000]}}]
    }}


def _notion_paragraph(text):
    return {"object": "block", "type": "paragraph", "paragraph": {
        "rich_text": [{"text": {"content": text[:2000]}}]
    }}


def _notion_bullet(text):
    return {"object": "block", "type": "bulleted_list_item", "bulleted_list_item": {
        "rich_text": [{"text": {"content": text[:2000]}}]
    }}


def _notion_code(text, language="shell"):
    return {"object": "block", "type": "code", "code": {
        "rich_text": [{"text": {"content": text[:2000]}}],
        "language": language,
    }}


def _notion_callout(text, emoji="💡"):
    return {"object": "block", "type": "callout", "callout": {
        "icon": {"emoji": emoji},
        "rich_text": [{"text": {"content": text[:2000]}}]
    }}


def _notion_divider():
    return {"object": "block", "type": "divider", "divider": {}}


def _parse_rich_text(text):
    """Parse markdown **bold** and `code` into Notion rich_text annotations."""
    import re
    parts = []
    # Split by **bold** and `code` patterns
    pattern = re.compile(r'(\*\*.*?\*\*|`[^`]+`)')
    last_end = 0
    for match in pattern.finditer(text):
        # Add plain text before match
        if match.start() > last_end:
            plain = text[last_end:match.start()]
            if plain:
                parts.append({"text": {"content": plain}})
        token = match.group()
        if token.startswith("**") and token.endswith("**"):
            parts.append({"text": {"content": token[2:-2]}, "annotations": {"bold": True}})
        elif token.startswith("`") and token.endswith("`"):
            parts.append({"text": {"content": token[1:-1]}, "annotations": {"code": True}})
        last_end = match.end()
    # Remaining text
    if last_end < len(text):
        remaining = text[last_end:]
        if remaining:
            parts.append({"text": {"content": remaining}})
    return parts if parts else [{"text": {"content": text}}]


def _notion_paragraph_rich(text):
    return {"object": "block", "type": "paragraph", "paragraph": {
        "rich_text": _parse_rich_text(text[:2000])
    }}


def _notion_bullet_rich(text):
    return {"object": "block", "type": "bulleted_list_item", "bulleted_list_item": {
        "rich_text": _parse_rich_text(text[:2000])
    }}
