"""
Lambda function: Upgrade Plan Analyzer for Version Drift Alerts

Triggered by the "📋 Upgrade Plan" button on Teams version-drift alert cards.
Fetches GitHub release notes for the version range, calls Claude to generate
a structured upgrade plan, writes it to Notion, runs pre-upgrade steps via SSM,
and replies in the Teams thread with a short card containing the Notion link.

Architecture:
    bot-endpoint Lambda -> This Lambda (async)
        Phase 1: Read current/latest versions from event (labels → AMP fallback)
        Phase 2: Fetch GitHub release notes + internal validator-context docs
        Phase 3: Claude API → structured JSON upgrade plan
        Phase 4a: SSM pre-upgrade steps on each instance
        Phase 4b: Notion — search for existing page or create new one
        Phase 4c: Teams short card (Notion link + Post-Upgrade Verify button)

    Post-upgrade (action_type="run_post_upgrade"):
        SSM post-upgrade commands → Notion append → Teams verification summary

Environment variables:
    ANTHROPIC_SECRET_ARN: Secrets Manager ARN — JSON with "api_key" (required)
                          and optional "github_token" for validator-context access
    TEAMS_BOT_SECRET_ARN: Secrets Manager ARN for Bot Framework credentials
    NOTION_SECRET_ARN:    Secrets Manager ARN for Notion API token (optional)
    AMP_WORKSPACE_ID: Amazon Managed Prometheus workspace ID
    AMP_REGION: AMP region (default us-east-1)
    SSM_REGION: Region for SSM commands (default us-east-1)
"""

import base64
import json
import logging
import os
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone

import boto3
import botocore.auth
import botocore.awsrequest
import botocore.credentials
import botocore.session

logger = logging.getLogger()
logger.setLevel(logging.INFO)

secrets_client = boto3.client("secretsmanager")
ssm_client = boto3.client("ssm", region_name=os.environ.get("SSM_REGION", "us-east-1"))

# Cached secrets / tokens
_anthropic_api_key = None
_bot_config = None
_bot_token = None
_bot_token_expires = 0
_notion_token = None

CLAUDE_MODEL = "claude-sonnet-4-6"
CLAUDE_MAX_TOKENS = 4096

# =============================================================================
# Chain Configuration
# =============================================================================

VALIDATOR_CONTEXT_REPO = "blueprint-infrastructure/validator-context"

# Normalize chain aliases sent by teams-notifier (e.g. "avax" → "avalanche")
CHAIN_ALIASES = {
    "avax":      "avalanche",
    "eth":       "ethereum",
    "algo":      "algorand",
    "cc":        "audius",
}

CHAIN_REPOS = {
    "avalanche": ["ava-labs/avalanchego"],
    "solana":    ["anza-xyz/agave"],
    "algorand":  ["algorand/go-algorand"],
    "ethereum":  ["besu-eth/besu", "Consensys/teku"],  # filtered by alertname
    "audius":    ["AudiusProject/audius-protocol"],
    "canton":    [],
}

# AMP instant-query metric names for version labels
# Each tuple: (current_version_metric, latest_version_metric)
VERSION_METRICS = {
    "avalanche": ("avalanche_node_version",     "avalanche_latest_version"),
    "solana":    ("solana_node_version",        "solana_latest_version"),
    "algorand":  ("algorand_node_version",      "algorand_latest_version"),
    "ethereum":  ("ethereum_besu_version",      "ethereum_besu_latest_version"),
}

# Operational context injected into Claude's system prompt
CHAIN_UPGRADE_CONTEXT = {
    "avalanche": (
        "Service: avalanchego (systemctl). "
        "IMPORTANT: Default user is ubuntu, NOT root. SSM runs as root, so use absolute paths. "
        "Config dir: /home/ubuntu/.avalanchego/ (NOT ~/.avalanchego — that resolves to /root which is wrong). "
        "Binary paths vary per node: some use /usr/local/bin/avalanchego (systemd ExecStart), others use /home/ubuntu/avalanche-node/avalanchego (installer default). "
        "Pre-upgrade check MUST verify which path systemd uses: grep ExecStart /etc/systemd/system/avalanchego.service. "
        "Upgrade method: Use the official AvalancheGo installer script from Avalanche docs. "
        "  Upgrade command (run as ubuntu, NOT root): cd /home/ubuntu && wget -q https://raw.githubusercontent.com/AshAvalanche/avalanche-docs/master/scripts/avalanchego-installer.sh && chmod +x avalanchego-installer.sh && ./avalanchego-installer.sh --version v<TARGET_VERSION>. "
        "  IMPORTANT: The version MUST have a 'v' prefix (e.g. v1.14.2, NOT 1.14.2). Without it the installer tries to build from source and fails. "
        "  IMPORTANT: The installer must NOT be run as root — it will refuse. Run as the ubuntu user. Since SSM runs as root, upgrade_steps commands that use the installer must be prefixed with: sudo -u ubuntu bash -c '...'. "
        "  The installer downloads the binary to ~/avalanche-node/ but systemd ExecStart may point to /usr/local/bin/avalanchego. "
        "  upgrade_steps MUST: 1) su ubuntu to switch user, 2) run the installer, 3) sudo systemctl stop avalanchego, 4) sudo cp ~/avalanche-node/avalanchego /usr/local/bin/avalanchego, 5) sudo systemctl start avalanchego. "
        "  IMPORTANT: All upgrade_steps run inside 'su ubuntu' context. The installer refuses root. After installer finishes, stop service then copy binary then start service (cannot cp while service is running — 'Text file busy'). "
        "Pre-upgrade checks: /home/ubuntu/avalanche-node/avalanchego --version; systemctl is-active avalanchego; "
        "  curl -s -X POST --data '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"info.isBootstrapped\",\"params\":{\"chain\":\"X\"}}' -H 'content-type:application/json;' http://127.0.0.1:9650/ext/info; "
        "  df -h /home/ubuntu/.avalanchego. "
        "Post-upgrade verify: /home/ubuntu/avalanche-node/avalanchego --version; systemctl is-active avalanchego; "
        "  curl -s -X POST --data '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"info.isBootstrapped\",\"params\":{\"chain\":\"X\"}}' -H 'content-type:application/json;' http://127.0.0.1:9650/ext/info."
    ),
    "solana": (
        "Service: sol (systemctl) or agave-validator. "
        "Restart: systemctl restart sol. "
        "Verify: solana-validator --version; agave-validator monitor --ledger /mnt/ledger. "
        "Note: snapshot restart may be required after major upgrades."
    ),
    "algorand": (
        "Service: algorand (systemctl). "
        "Package manager: apt (Ubuntu) — apt-get install algorand. "
        "Data dir: /var/lib/algorand. "
        "Verify: goal node status -d /var/lib/algorand. "
        "Note: catchpoint fast-sync may be needed after major version jumps."
    ),
    "ethereum": (
        "Deployed via Stereum — both Besu (execution layer) and Teku (consensus layer) run as Docker containers. "
        "IMPORTANT: Do NOT look for systemctl services or bare binaries. Use docker commands. "
        "Container names follow the pattern: stereum-<uuid>. "
        "Find containers: docker ps --format '{{.Names}} {{.Image}} {{.Status}}' | grep -iE 'besu|teku'. "
        "Besu image: hyperledger/besu:<version>. Teku image: consensys/teku:<version>. "
        "Rolling upgrade order: upgrade teku first, then besu. "
        "Pre-upgrade checks should use docker exec: "
        "  docker exec $(docker ps -q -f ancestor=hyperledger/besu) besu --version; "
        "  docker exec $(docker ps -q -f ancestor=consensys/teku --latest) /opt/teku/bin/teku --version; "
        "  curl -s http://localhost:5051/eth/v1/node/syncing; "
        "  curl -s http://localhost:8545 -X POST -H 'Content-Type: application/json' -d '{\"jsonrpc\":\"2.0\",\"method\":\"eth_syncing\",\"params\":[],\"id\":1}'. "
        "Upgrade: update the image tag in Stereum config, then docker compose pull && docker compose up -d, or docker stop + docker rm + docker run with new image tag. "
        "Default user is ubuntu, SSM runs as root — use absolute paths."
    ),
    "audius": (
        "Deployed via direct 'docker run' (NOT docker-compose). "
        "Container name: my-node. Image: openaudio/go-openaudio:stable. "
        "Data volume: /root/openaudio-prod-data:/data. Ports: 80, 443, 26656. "
        "Restart policy: unless-stopped. "
        "Pre-upgrade checks: docker ps; docker inspect my-node --format '{{.Config.Image}}'; curl -s http://localhost/health_check. "
        "Upgrade steps: 1) docker pull openaudio/go-openaudio:stable, "
        "2) Save current container config: docker inspect my-node > /tmp/my-node-backup.json, "
        "3) docker stop my-node && docker rm my-node, "
        "4) Recreate with same env vars and mounts: docker run -d --name my-node --restart unless-stopped "
        "-v /root/openaudio-prod-data:/data -p 80:80 -p 443:443 -p 26656:26656 "
        "$(docker inspect my-node 2>/dev/null | python3 -c \"import json,sys; c=json.load(sys.stdin)[0]; print(' '.join(f'-e {e.split(\\\"=\\\",1)[0]}=...' for e in c['Config']['Env'] if 'PATH' not in e.split('=',1)[0]))\" 2>/dev/null) "
        "openaudio/go-openaudio:stable. "
        "IMPORTANT: Container env vars include PRIVATE KEYS — NEVER log, print, or include them in any output, plan, or documentation. "
        "Use 'docker inspect my-node' to get the full run command for recreation, but redact all private key values. "
        "Verify: docker ps | grep my-node; curl -s http://localhost/health_check."
    ),
    "canton": (
        "Canton Enterprise node. "
        "Check official release docs for database migration scripts before upgrading. "
        "Restart: docker compose down && docker compose up -d. "
        "Verify: docker compose logs --tail=50."
    ),
}

# Notion parent page IDs per chain (sub-pages will be created under these)
NOTION_CHAIN_PAGES = {
    "avalanche": "32f09a37-0ee0-8146-80fd-c77d94fcc1cb",
    "solana":    "32f09a37-0ee0-81f6-85a6-ea797c34e9fe",
    "ethereum":  "32f09a37-0ee0-81ab-bb69-ec252276c988",
    "algorand":  "32f09a37-0ee0-81f8-9b28-c2db2d280999",
    "audius":    "32f09a37-0ee0-8166-9f38-edbff0b15df1",
}

# =============================================================================
# Phase 1: Version Discovery
# =============================================================================

def _get_versions(chain, instance, labels, alertname="", current_ver_hint="", latest_ver_hint=""):
    """Discover current and latest version strings.

    Priority: event hints → labels → AMP → GitHub latest tag.
    Returns (current_ver, latest_ver) — either may be "unknown" if not found.
    """
    # Try 0: version hints passed directly from the button data
    if current_ver_hint and latest_ver_hint:
        logger.info("Versions from event: current=%s latest=%s", current_ver_hint, latest_ver_hint)
        return current_ver_hint, latest_ver_hint

    # Try 1: labels passed from the alert
    current_ver = labels.get("version", "")
    latest_ver = labels.get("latest_version", "")
    if current_ver and latest_ver:
        logger.info("Versions from labels: current=%s latest=%s", current_ver, latest_ver)
        return current_ver, latest_ver

    # Try 2: AMP instant query for version label metrics
    workspace_id = os.environ.get("AMP_WORKSPACE_ID", "")
    region = os.environ.get("AMP_REGION", "us-east-1")
    if workspace_id and chain in VERSION_METRICS:
        cur_metric, lat_metric = VERSION_METRICS[chain]
        if chain == "ethereum":
            if "Teku" in alertname:
                cur_metric = "ethereum_teku_version"
                lat_metric = "ethereum_teku_latest_version"
        try:
            current_ver = _query_amp_version_label(workspace_id, region, cur_metric, instance)
            latest_ver = _query_amp_version_label(workspace_id, region, lat_metric, instance)
            logger.info("Versions from AMP: current=%s latest=%s", current_ver, latest_ver)
        except Exception as e:
            logger.warning("AMP version query failed: %s", e)

    # Try 3: GitHub latest release as fallback for latest_ver
    repos = _get_repos_for_chain(chain, alertname, single=True)
    if not latest_ver and repos:
        try:
            latest_ver = _get_latest_tag(repos[0])
            logger.info("Latest version from GitHub: %s", latest_ver)
        except Exception as e:
            logger.warning("GitHub latest tag fetch failed: %s", e)

    return current_ver or current_ver_hint or "unknown", latest_ver or latest_ver_hint or "unknown"


def _query_amp_version_label(workspace_id, region, metric_name, instance):
    """Query AMP for a version metric and extract the 'version' label value."""
    query = f'{metric_name}{{instance=~".*{instance.split(":")[0]}.*"}}'
    host = f"aps-workspaces.{region}.amazonaws.com"
    path = f"/workspaces/{workspace_id}/api/v1/query"
    query_params = {"query": query}

    boto_session = boto3.Session()
    credentials = boto_session.get_credentials().get_frozen_credentials()
    base_url = f"https://{host}{path}"
    aws_request = botocore.awsrequest.AWSRequest(
        method="GET",
        url=base_url,
        params=query_params,
        headers={"Host": host},
    )
    signer = botocore.auth.SigV4Auth(credentials, "aps", region)
    signer.add_auth(aws_request)
    prepared = aws_request.prepare()

    req = urllib.request.Request(
        prepared.url,
        headers=dict(prepared.headers),
        method="GET",
    )

    with urllib.request.urlopen(req, timeout=10) as response:
        resp_data = json.loads(response.read().decode("utf-8"))

    if resp_data.get("status") != "success":
        return ""

    results = resp_data.get("data", {}).get("result", [])
    if not results:
        return ""

    metric_labels = results[0].get("metric", {})
    return (
        metric_labels.get("version", "")
        or metric_labels.get("value", "")
        or ""
    )


# =============================================================================
# Phase 2: GitHub Release Notes
# =============================================================================

def _get_repos_for_chain(chain, alertname="", single=False):
    """Return the list of GitHub repos for this chain/alertname.

    For ethereum, returns BOTH besu and teku repos by default (needed for
    release notes and upgrade plans). Pass single=True to filter to just
    the repo matching the alertname (used for version discovery fallback).
    """
    repos = CHAIN_REPOS.get(chain, [])
    if single and chain == "ethereum" and len(repos) == 2:
        if "Teku" in alertname:
            return [r for r in repos if "teku" in r.lower()]
        else:
            return [r for r in repos if "besu" in r.lower()]
    return repos


def _get_latest_tag(repo):
    """Fetch the latest release tag from GitHub."""
    url = f"https://api.github.com/repos/{repo}/releases/latest"
    req = urllib.request.Request(
        url,
        headers={
            "Accept": "application/vnd.github+json",
            "User-Agent": "staking-alert-upgrade-analyzer",
        },
        method="GET",
    )
    with urllib.request.urlopen(req, timeout=10) as response:
        data = json.loads(response.read().decode("utf-8"))
    return data.get("tag_name", "")


def _fetch_releases(repo, count=15, since_version=""):
    """Fetch recent GitHub releases, optionally filtering to those after since_version."""
    url = f"https://api.github.com/repos/{repo}/releases?per_page={count}"
    req = urllib.request.Request(
        url,
        headers={
            "Accept": "application/vnd.github+json",
            "User-Agent": "staking-alert-upgrade-analyzer",
        },
        method="GET",
    )

    try:
        with urllib.request.urlopen(req, timeout=15) as response:
            releases = json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        logger.warning("GitHub API error %d for %s: %s", e.code, repo, e.read().decode()[:200])
        return ""
    except Exception as e:
        logger.warning("GitHub fetch failed for %s: %s", repo, e)
        return ""

    parts = []
    for release in releases:
        tag = release.get("tag_name", "")
        name = release.get("name", tag)
        body = (release.get("body", "") or "").strip()
        if since_version and since_version != "unknown" and tag:
            if _tag_lte(tag, since_version):
                continue
        if body:
            parts.append(f"### {name} ({tag})\n{body[:2500]}")

    return "\n\n---\n\n".join(parts) if parts else "No release notes found."


def _tag_lte(tag_a, tag_b):
    """Return True if tag_a is older than or equal to tag_b (best-effort semver compare)."""
    def _parse(t):
        t = t.lstrip("v").split("-")[0]
        try:
            return tuple(int(x) for x in t.split("."))
        except ValueError:
            return (0,)
    return _parse(tag_a) <= _parse(tag_b)


def _fetch_validator_context(chain):
    """Fetch internal upgrade docs from blueprint-infrastructure/validator-context (best-effort)."""
    github_token = _get_github_token()
    if not github_token:
        return ""

    headers = {
        "Authorization": f"Bearer {github_token}",
        "Accept": "application/vnd.github+json",
        "User-Agent": "staking-alert-upgrade-analyzer",
    }
    results = []

    wiki_url = (
        f"https://api.github.com/repos/{VALIDATOR_CONTEXT_REPO}"
        f"/contents/{chain}/wiki/upgrade.md"
    )
    try:
        req = urllib.request.Request(wiki_url, headers=headers, method="GET")
        with urllib.request.urlopen(req, timeout=8) as resp:
            file_data = json.loads(resp.read())
            content = base64.b64decode(file_data["content"]).decode("utf-8").strip()
            if content:
                results.append(
                    f"=== Internal Upgrade Guide ({chain}/wiki/upgrade.md) ===\n{content[:3000]}"
                )
    except urllib.error.HTTPError as e:
        if e.code != 404:
            logger.warning("validator-context wiki fetch HTTP %d for %s", e.code, chain)
    except Exception as e:
        logger.warning("validator-context wiki fetch failed for %s: %s", chain, e)

    scripts_url = (
        f"https://api.github.com/repos/{VALIDATOR_CONTEXT_REPO}"
        f"/contents/{chain}/scripts"
    )
    try:
        req = urllib.request.Request(scripts_url, headers=headers, method="GET")
        with urllib.request.urlopen(req, timeout=8) as resp:
            files = json.loads(resp.read())
            for f in files:
                if f["name"] == ".gitkeep" or f.get("size", 0) == 0:
                    continue
                download_url = f.get("download_url", "")
                if not download_url:
                    continue
                try:
                    dl_req = urllib.request.Request(
                        download_url,
                        headers={
                            "Authorization": f"Bearer {github_token}",
                            "User-Agent": "staking-alert-upgrade-analyzer",
                        },
                        method="GET",
                    )
                    with urllib.request.urlopen(dl_req, timeout=8) as fr:
                        script_content = fr.read().decode("utf-8").strip()
                        if script_content:
                            results.append(
                                f"=== Internal Script: {f['name']} ===\n{script_content[:2000]}"
                            )
                except Exception as e:
                    logger.warning("Failed to fetch script %s: %s", f["name"], e)
    except urllib.error.HTTPError as e:
        if e.code != 404:
            logger.warning("validator-context scripts fetch HTTP %d for %s", e.code, chain)
    except Exception as e:
        logger.warning("validator-context scripts fetch failed for %s: %s", chain, e)

    if results:
        logger.info("validator-context: fetched %d item(s) for chain=%s", len(results), chain)
    return "\n\n".join(results)


# =============================================================================
# Phase 3: Claude Upgrade Plan Generation
# =============================================================================

UPGRADE_SYSTEM_PROMPT = """You are a blockchain infrastructure engineer helping a validator node operator plan a software upgrade.

Given the chain name, current version, target version, operational context, and GitHub release notes, produce a concise actionable upgrade plan.

Respond ONLY with valid JSON — no markdown fences, no extra text. Use exactly this structure:
{
  "summary": "One-line overview of what is changing",
  "breaking_changes": ["list each breaking change — empty array if none"],
  "pre_upgrade_steps": [{"step": "1", "description": "...", "command": "..."}],
  "upgrade_steps":     [{"step": "1", "description": "...", "command": "..."}],
  "post_upgrade_steps":[{"step": "1", "description": "...", "command": "..."}],
  "rollback_steps":    ["step 1: ...", "step 2: ..."],
  "estimated_downtime": "e.g. ~5 min | None (rolling restart)",
  "notes": "any additional context or caveats"
}

Rules:
- Include actual shell commands wherever applicable.
- Keep each step description under 120 characters.
- If release notes are unavailable or sparse, still provide a reasonable generic plan.
- Only include breaking_changes that are explicitly mentioned or clearly implied by the release notes.
- NEVER assume the current working directory. Always use absolute paths or cd to the correct directory first.
- SSM runs as root, but the default user on nodes is ubuntu. Use absolute paths like /home/ubuntu/.avalanchego/ instead of ~ or $HOME which resolve to /root.
- For docker-compose based services, always locate the compose file before running compose commands.
- NEVER include private keys, secrets, or sensitive credentials in commands, output, or documentation. Redact them as '***'.
- pre_upgrade_steps are auto-executed via SSM. They must ONLY contain read-only diagnostic checks (version, config, disk space, health). NEVER include downloads, installs, backups, or any write operations in pre_upgrade_steps — those belong in upgrade_steps.
- upgrade_steps are manual. Downloads, binary replacement, service restarts, and backups go here.
"""


def _generate_upgrade_plan(chain, instances, current_ver, latest_ver, release_notes, alertname=""):
    """Call Claude to generate a structured upgrade plan JSON."""
    api_key = _get_anthropic_key()
    if not api_key:
        raise RuntimeError("Anthropic API key not available")

    chain_ctx = CHAIN_UPGRADE_CONTEXT.get(chain, "No chain-specific context available.")
    instance_list = ", ".join(i["name"] for i in instances) if instances else "unknown"

    user_message = f"""Chain: {chain}
Alert: {alertname}
Instances: {instance_list}
Current version: {current_ver}
Target version: {latest_ver}

Operational context:
{chain_ctx}

GitHub release notes ({current_ver} → {latest_ver}):
{release_notes[:8000]}

Generate the upgrade plan JSON now."""

    raw = _call_claude(api_key, UPGRADE_SYSTEM_PROMPT, user_message)

    cleaned = raw.strip()
    if cleaned.startswith("```"):
        lines = cleaned.split("\n")
        lines = [l for l in lines if not l.strip().startswith("```")]
        cleaned = "\n".join(lines).strip()

    try:
        plan = json.loads(cleaned)
    except json.JSONDecodeError as e:
        logger.error("Claude returned non-JSON: %s", raw[:500])
        plan = {
            "summary": f"Upgrade {chain} from {current_ver} to {latest_ver}",
            "breaking_changes": [],
            "pre_upgrade_steps": [{"step": "1", "description": "Review release notes", "command": ""}],
            "upgrade_steps": [{"step": "1", "description": "Follow official upgrade guide", "command": ""}],
            "post_upgrade_steps": [{"step": "1", "description": "Verify node is healthy", "command": ""}],
            "rollback_steps": ["Restore previous binary", "Restart service"],
            "estimated_downtime": "Unknown",
            "notes": f"Auto-generation failed ({e}). Please review release notes manually.",
        }

    return plan


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


def _notion_callout(text, emoji="📋"):
    return {"object": "block", "type": "callout", "callout": {
        "icon": {"emoji": emoji},
        "rich_text": [{"text": {"content": text[:2000]}}]
    }}


def _notion_divider():
    return {"object": "block", "type": "divider", "divider": {}}


def _notion_request(token, method, url, payload=None):
    """Make a Notion API call, bypassing Cloudflare TLS fingerprint blocking.

    Lambda's default Python TLS and curl produce JA3 fingerprints that Cloudflare
    blocks for Notion write endpoints. We try multiple TLS configurations to find
    one that passes:
      1. requests + custom SSL context (altered cipher order → different JA3)
      2. curl with --ciphers / --tls-max flags
      3. requests with default TLS (might work if Cloudflare rules change)

    Returns parsed JSON response dict, or raises RuntimeError on failure.
    """
    headers = {
        "Authorization": f"Bearer {token}",
        "Notion-Version": "2022-06-28",
        "Content-Type": "application/json",
    }
    body = json.dumps(payload).encode("utf-8") if payload is not None else None

    # --- curl_cffi with Chrome TLS fingerprint (bypasses Cloudflare JA3 detection) ---
    try:
        from curl_cffi import requests as cf_requests
        resp = cf_requests.request(
            method, url, headers=headers, data=body,
            impersonate="chrome120", timeout=20,
        )
        if resp.status_code < 400:
            logger.info("Notion curl_cffi %s %s → HTTP %d", method, url.split("notion.com")[1], resp.status_code)
            return resp.json() if resp.content else {}
        raise RuntimeError(f"Notion API HTTP {resp.status_code}: {resp.text[:300]}")
    except ImportError:
        logger.warning("curl_cffi not available — falling back to requests")
    except RuntimeError:
        raise
    except Exception as e:
        logger.warning("curl_cffi failed (%s) — falling back to requests", e)

    # --- Fallback: plain requests (works when Cloudflare is not blocking) ---
    try:
        import requests as _requests
        resp = _requests.request(method, url, headers=headers, data=body, timeout=20)
        if resp.status_code < 400:
            logger.info("Notion requests %s %s → HTTP %d", method, url.split("notion.com")[1], resp.status_code)
            return resp.json() if resp.content else {}
        raise RuntimeError(f"Notion API HTTP {resp.status_code}: {resp.text[:300]}")
    except ImportError:
        logger.warning("requests not available")
    except RuntimeError:
        raise

    logger.info("Notion curl %s %s → HTTP %s", method, url.split("notion.com")[1], http_code)
    if resp_body.startswith("{") or resp_body.startswith("["):
        return json.loads(resp_body)
    return {}


def _notion_append_blocks(token, page_id, blocks, batch_size=8):
    """Append blocks to a Notion page in batches.

    Cloudflare rate-limits PATCH requests to ~3-4 per window. Using larger
    batches (8 blocks) with 5-second delays minimizes total PATCH count.
    On 403, waits 30 seconds then retries once.
    """
    url = f"https://api.notion.com/v1/blocks/{page_id}/children"
    for i in range(0, len(blocks), batch_size):
        if i > 0:
            time.sleep(5)
        chunk = blocks[i:i + batch_size]
        try:
            _notion_request(token, "PATCH", url, {"children": chunk})
        except RuntimeError as e:
            if "403" in str(e):
                logger.warning("Cloudflare rate limit — waiting 30s for single retry")
                time.sleep(30)
                _notion_request(token, "PATCH", url, {"children": chunk})
            else:
                raise


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


def _notion_search_page(token, title):
    """Search for a Notion page by exact title. Returns (page_id, page_url) or (None, None)."""
    data = json.dumps({
        "query": title,
        "filter": {"property": "object", "value": "page"},
    }).encode("utf-8")
    req = urllib.request.Request(
        "https://api.notion.com/v1/search",
        data=data,
        headers={
            "Authorization": f"Bearer {token}",
            "Notion-Version": "2022-06-28",
            "Content-Type": "application/json",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            results = json.loads(resp.read()).get("results", [])
    except Exception as e:
        logger.warning("Notion search failed: %s", e)
        return None, None

    for page in results:
        # Match exact title
        props = page.get("properties", {})
        title_prop = props.get("title", {}).get("title", [])
        page_title = "".join(t.get("plain_text", "") for t in title_prop)
        if page_title == title:
            page_id = page["id"]
            page_url = page.get("url", f"https://www.notion.so/{page_id.replace('-', '')}")
            logger.info("Found existing Notion page: %s (%s)", title, page_id)
            return page_id, page_url

    return None, None


def _notion_create_page(token, parent_page_id, title, blocks):
    """Create a new Notion page under parent_page_id. Returns (page_id, page_url).

    Sends ALL blocks in a single POST request. No retries, no PATCH fallback.
    Cloudflare Bot Fight Mode rate-limits Lambda — keeping to exactly 1 write
    request per upgrade plan preserves the NAT IP's reputation.
    """
    payload = {
        "parent": {"page_id": parent_page_id},
        "properties": {
            "title": {"title": [{"text": {"content": title}}]}
        },
    }
    if blocks:
        payload["children"] = blocks[:100]

    page = _notion_request(token, "POST", "https://api.notion.com/v1/pages", payload)

    page_id = page["id"]
    page_url = page.get("url", f"https://www.notion.so/{page_id.replace('-', '')}")
    logger.info("Created Notion page: %s (%s) — %d blocks", title, page_id, min(len(blocks), 100))
    return page_id, page_url


def _notion_archive_page(token, page_id):
    """Archive (soft-delete) a Notion page."""
    data = json.dumps({"archived": True}).encode("utf-8")
    req = urllib.request.Request(
        f"https://api.notion.com/v1/pages/{page_id}",
        data=data,
        headers={
            "Authorization": f"Bearer {token}",
            "Notion-Version": "2022-06-28",
            "Content-Type": "application/json",
        },
        method="PATCH",
    )
    with urllib.request.urlopen(req, timeout=10) as resp:
        resp.read()
    logger.info("Archived Notion page: %s", page_id)


def _notion_link_paragraph(text, url):
    """Notion paragraph block with a clickable hyperlink."""
    return {
        "object": "block",
        "type": "paragraph",
        "paragraph": {
            "rich_text": [{
                "type": "text",
                "text": {"content": text, "link": {"url": url}},
                "annotations": {"bold": False, "italic": False, "underline": True,
                                "strikethrough": False, "code": False, "color": "blue"},
            }]
        },
    }


def _release_notes_urls(chain, latest_ver, alertname=""):
    """Build GitHub release URLs for the target version."""
    repos = _get_repos_for_chain(chain, alertname)
    urls = []
    for repo in repos:
        tag = _extract_version_tag(repo, latest_ver)
        urls.append((f"{repo} release: {tag}", f"https://github.com/{repo}/releases/tag/{tag}"))
    return urls


def _extract_version_tag(repo, version_str):
    """Extract the correct release tag for a repo from a possibly compound version string.

    Examples:
      repo="besu-eth/besu",   version="Besu 26.2.0 / Teku 26.4.0"  → "26.2.0"
      repo="Consensys/teku",  version="Besu 26.2.0 / Teku 26.4.0"  → "26.4.0"
      repo="ava-labs/avalanchego", version="AvalancheGo 1.14.2"     → "AvalancheGo 1.14.2"
    """
    import re
    repo_lower = repo.lower()
    ver = version_str.strip()

    # Handle compound version: "Besu 26.2.0 / Teku 26.4.0"
    if "/" in ver:
        parts = [p.strip() for p in ver.split("/")]
        for part in parts:
            # Match repo name to version part
            if "besu" in repo_lower and part.lower().startswith("besu"):
                return re.sub(r'^[A-Za-z]+\s*', '', part).strip()
            if "teku" in repo_lower and part.lower().startswith("teku"):
                return re.sub(r'^[A-Za-z]+\s*', '', part).strip()
        # No match — return first part stripped of prefix
        return re.sub(r'^[A-Za-z]+\s*', '', parts[0]).strip()

    # Single version: "Besu 26.2.0" → "26.2.0" for besu-eth/besu
    if "besu" in repo_lower and ver.lower().startswith("besu"):
        return re.sub(r'^[A-Za-z]+\s*', '', ver).strip()
    if "teku" in repo_lower and ver.lower().startswith("teku"):
        return re.sub(r'^[A-Za-z]+\s*', '', ver).strip()

    return ver


def _build_notion_blocks(plan, pre_results, instances, chain, current_ver, latest_ver, alertname=""):
    """Convert an upgrade plan + SSM pre-upgrade results into compact Notion blocks.

    Cloudflare WAF limits us to ~18 blocks per page creation (POST with 10 +
    1 PATCH of 8). Content is compressed: multiple steps merged into single
    code blocks, SSM output combined, dividers minimized.
    """
    now = datetime.now(tz=timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    instance_names = ", ".join(i["name"] for i in instances) if instances else "—"

    blocks = []

    # 1. Header callout
    blocks.append(_notion_callout(
        f"Chain: {chain.capitalize()}  |  {current_ver} → {latest_ver}\n"
        f"Instances: {instance_names}\n"
        f"Generated: {now}",
        "📋",
    ))

    # 2. Release notes links
    release_urls = _release_notes_urls(chain, latest_ver, alertname)
    if release_urls:
        for link_text, url in release_urls:
            blocks.append(_notion_link_paragraph(link_text, url))

    # 3. Summary + Breaking Changes (combined)
    summary = plan.get("summary", "—")
    breaking = plan.get("breaking_changes", [])
    breaking_text = "\n".join(f"⚠️ {c}" for c in breaking) if breaking else "None"
    blocks.append(_notion_paragraph(
        f"Summary: {summary}\n\nBreaking Changes: {breaking_text}"[:2000]
    ))
    blocks.append(_notion_divider())

    # 4. Pre-upgrade steps — merge all commands into one code block
    pre_steps = plan.get("pre_upgrade_steps", [])
    if pre_steps:
        blocks.append(_notion_heading("Pre-Upgrade Steps (Auto-executed)"))
        cmds = "\n".join(
            f"# Step {s.get('step','')}: {s.get('description','')}\n{s.get('command','')}"
            for s in pre_steps if s.get("command")
        )
        if cmds:
            blocks.append(_notion_code(cmds[:2000]))

    # 5. SSM results — merge all into one code block
    if pre_results:
        combined_output = "\n".join(
            f"=== {r.get('instance_name','unknown')} ===\n{r.get('output','(no output)')}"
            for r in pre_results
        )
        blocks.append(_notion_code(combined_output[:2000], "plain text"))

    # 6. Upgrade steps (manual) — merge into one code block
    upgrade_steps = plan.get("upgrade_steps", [])
    if upgrade_steps:
        blocks.append(_notion_divider())
        blocks.append(_notion_callout(
            "⚠️ Upgrade Steps — must be performed manually by a human engineer.",
            "🛑",
        ))
        cmds = "\n\n".join(
            f"# Step {s.get('step','')}: {s.get('description','')}\n{s.get('command','')}"
            for s in upgrade_steps
        )
        if cmds:
            blocks.append(_notion_code(cmds[:2000]))

    # 7. Post-upgrade verification — merge into one code block
    post_steps = plan.get("post_upgrade_steps", [])
    if post_steps:
        blocks.append(_notion_divider())
        blocks.append(_notion_heading("Post-Upgrade Verification (Pending)"))
        cmds = "\n".join(
            f"# {s.get('step','')}: {s.get('description','')}\n{s.get('command','')}"
            for s in post_steps if s.get("command")
        )
        if cmds:
            blocks.append(_notion_code(cmds[:2000]))

    # 8. Rollback + Notes (combined)
    rollback = plan.get("rollback_steps", [])
    downtime = plan.get("estimated_downtime", "")
    notes = plan.get("notes", "")
    footer_parts = []
    if rollback:
        footer_parts.append("Rollback:\n" + "\n".join(f"• {s}" for s in rollback))
    if downtime:
        footer_parts.append(f"Estimated downtime: {downtime}")
    if notes:
        footer_parts.append(notes)
    if footer_parts:
        blocks.append(_notion_divider())
        blocks.append(_notion_paragraph("\n\n".join(footer_parts)[:2000]))

    logger.info("Built %d Notion blocks (compact mode)", len(blocks))
    return blocks


# =============================================================================
# GitHub Markdown Push
# =============================================================================

GITHUB_REPO = "blueprint-infrastructure/validator-context"


def _build_upgrade_plan_markdown(plan, pre_results, instances, chain, current_ver, latest_ver, alertname="", readiness_analysis=""):
    """Convert an upgrade plan into a Markdown document for GitHub."""
    now = datetime.now(tz=timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    instance_names = ", ".join(i["name"] for i in instances) if instances else "—"

    lines = []
    lines.append(f"# {chain.capitalize()} Upgrade Plan: {current_ver} → {latest_ver}")
    lines.append("")
    lines.append(f"- **Chain:** {chain.capitalize()}")
    lines.append(f"- **Instances:** {instance_names}")
    lines.append(f"- **Generated:** {now}")
    lines.append("")

    # Release notes
    release_urls = _release_notes_urls(chain, latest_ver, alertname)
    if release_urls:
        lines.append("## Release Notes")
        for link_text, url in release_urls:
            lines.append(f"- [{link_text}]({url})")
        lines.append("")

    # Summary
    lines.append("## Summary")
    lines.append(plan.get("summary", "—"))
    lines.append("")

    # Breaking changes
    breaking = plan.get("breaking_changes", [])
    lines.append("## Breaking Changes")
    if breaking:
        for change in breaking:
            lines.append(f"- ⚠️ {change}")
    else:
        lines.append("None")
    lines.append("")

    # Pre-upgrade steps — single code block with comments
    pre_steps = plan.get("pre_upgrade_steps", [])
    if pre_steps:
        lines.append("## Pre-Upgrade Steps (Auto-executed)")
        code_lines = []
        for s in pre_steps:
            code_lines.append(f"# Step {s.get('step', '')}: {s.get('description', '')}")
            if s.get("command"):
                code_lines.append(s["command"])
            code_lines.append("")
        lines.append(f"```bash\n{chr(10).join(code_lines).strip()}\n```")
        lines.append("")

    # SSM execution results — cleaned up
    if pre_results:
        lines.append("### Execution Results")
        for r in pre_results:
            inst_name = r.get("instance_name", "unknown")
            output = r.get("output", "(no output)")
            # Clean up SSM output: convert step markers, strip noise
            cleaned = []
            in_stderr = False
            for line in output.split("\n"):
                # Convert ===STEP N=== markers to comments
                if line.startswith("===STEP ") and line.endswith("==="):
                    step_num = line[8:-3].strip()
                    cleaned.append(f"# --- step {step_num} ---")
                    continue
                # Legacy ===CMD: markers
                if line.startswith("===CMD:") and line.endswith("==="):
                    continue
                # STDERR section header
                if line.strip() == "--- STDERR ---":
                    in_stderr = True
                    continue
                # Skip noisy STDERR lines
                if in_stderr:
                    # Skip SSM script path errors, curl progress bars, empty lines
                    if ("/awsrunShellScript/" in line or
                            line.strip().startswith("% Total") or
                            line.strip().startswith("Dload") or
                            "command not found" in line or
                            line.strip() == ""):
                        continue
                    # Keep meaningful errors
                    cleaned.append(f"# WARN: {line.strip()}")
                    continue
                # Skip curl progress bars in stdout
                if line.strip().startswith("% Total") or line.strip().startswith("Dload"):
                    continue
                cleaned.append(line)
            lines.append(f"**{inst_name}:**")
            lines.append(f"```\n{chr(10).join(cleaned)[:8000].strip()}\n```")
            lines.append("")

    # Readiness analysis (Claude-generated per-node assessment)
    if readiness_analysis:
        lines.append("## 🔍 Upgrade Readiness Assessment")
        lines.append(readiness_analysis)
        lines.append("")

    # Upgrade steps (manual) — single code block
    upgrade_steps = plan.get("upgrade_steps", [])
    if upgrade_steps:
        lines.append("## ⚠️ Upgrade Steps (Manual)")
        lines.append("> **These steps must be performed manually by a human engineer.**")
        lines.append("")
        code_lines = []
        for s in upgrade_steps:
            code_lines.append(f"# Step {s.get('step', '')}: {s.get('description', '')}")
            if s.get("command"):
                code_lines.append(s["command"])
            code_lines.append("")
        lines.append(f"```bash\n{chr(10).join(code_lines).strip()}\n```")
        lines.append("")

    # Post-upgrade verification — single code block
    post_steps = plan.get("post_upgrade_steps", [])
    if post_steps:
        lines.append("## Post-Upgrade Verification (Pending)")
        code_lines = []
        for s in post_steps:
            code_lines.append(f"# Step {s.get('step', '')}: {s.get('description', '')}")
            if s.get("command"):
                code_lines.append(s["command"])
            code_lines.append("")
        lines.append(f"```bash\n{chr(10).join(code_lines).strip()}\n```")
        lines.append("")

    # Rollback
    rollback = plan.get("rollback_steps", [])
    if rollback:
        lines.append("## Rollback Steps")
        for s in rollback:
            lines.append(f"1. `{s}`")
        lines.append("")

    # Notes
    downtime = plan.get("estimated_downtime", "")
    notes = plan.get("notes", "")
    if downtime or notes:
        lines.append("## Notes")
        if downtime:
            lines.append(f"- **Estimated downtime:** {downtime}")
        if notes:
            lines.append(f"- {notes}")
        lines.append("")

    return "\n".join(lines)


def _push_to_github(github_token, chain, filename, content, commit_message):
    """Push a file to the validator-context repo via GitHub API.

    Creates or updates the file at {chain}/upgrade_plan/{filename}.
    Returns the HTML URL of the file, or None on failure.
    """
    path = f"{chain}/upgrade_plan/{filename}"
    api_url = f"https://api.github.com/repos/{GITHUB_REPO}/contents/{path}"
    headers = {
        "Authorization": f"Bearer {github_token}",
        "Accept": "application/vnd.github+json",
        "User-Agent": "staking-alert-upgrade-analyzer",
    }

    # Check if file already exists (need its SHA for update)
    sha = None
    get_req = urllib.request.Request(api_url, headers=headers, method="GET")
    try:
        with urllib.request.urlopen(get_req, timeout=10) as resp:
            existing = json.loads(resp.read())
            sha = existing.get("sha")
    except Exception:
        pass  # File doesn't exist yet — will create

    payload = {
        "message": commit_message,
        "content": base64.b64encode(content.encode("utf-8")).decode("ascii"),
    }
    if sha:
        payload["sha"] = sha

    data = json.dumps(payload).encode("utf-8")
    put_req = urllib.request.Request(api_url, data=data, headers=headers, method="PUT")
    put_req.add_header("Content-Type", "application/json")

    try:
        with urllib.request.urlopen(put_req, timeout=15) as resp:
            result = json.loads(resp.read())
            html_url = result.get("content", {}).get("html_url", "")
            logger.info("Pushed upgrade plan to GitHub: %s", html_url)
            return html_url
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", errors="replace")[:300]
        logger.error("GitHub push failed: HTTP %d — %s", e.code, body)
        return None
    except Exception as e:
        logger.error("GitHub push failed: %s", e)
        return None


def _analyze_pre_upgrade_results(api_key, chain, current_ver, latest_ver, plan, pre_results):
    """Call Claude to analyze pre-upgrade SSM results and assess each node's readiness."""
    results_text = ""
    for r in pre_results:
        results_text += f"\n### {r.get('instance_name', 'unknown')}:\n{r.get('output', '(no output)')[:2000]}\n"

    breaking = plan.get("breaking_changes", [])
    breaking_text = "\n".join(f"- {c}" for c in breaking) if breaking else "None"

    prompt = (
        f"You are analyzing pre-upgrade check results for {chain} nodes upgrading from {current_ver} to {latest_ver}.\n\n"
        f"Breaking changes:\n{breaking_text}\n\n"
        f"Pre-upgrade execution results:\n{results_text}\n\n"
        "For EACH node, provide:\n"
        "1. **Status**: ✅ Ready / ⚠️ Ready with caution / ❌ Not ready\n"
        "2. **Key findings**: What the checks revealed (1-2 sentences)\n"
        "3. **Action items**: Any issues that must be fixed before upgrading (if any)\n\n"
        "Be concise. Use markdown formatting. Focus on blocking issues vs warnings."
    )

    try:
        result = _call_claude(api_key, "You are a DevOps engineer analyzing pre-upgrade readiness.", prompt)
        return result
    except Exception as e:
        logger.warning("Readiness analysis Claude call failed: %s", e)
        return ""


# =============================================================================
# SSM Command Execution
# =============================================================================

_instance_region_cache = {}


def _discover_instance_region(instance_id):
    """Find which AWS region an SSM-managed instance is in by querying all regions."""
    if instance_id in _instance_region_cache:
        return _instance_region_cache[instance_id]

    regions = ["us-east-1", "us-west-2", "us-west-1", "us-east-2", "eu-west-1"]
    for region in regions:
        try:
            ssm = boto3.client("ssm", region_name=region)
            resp = ssm.describe_instance_information(
                Filters=[{"Key": "InstanceIds", "Values": [instance_id]}],
            )
            if resp.get("InstanceInformationList"):
                logger.info("Discovered instance %s in region %s", instance_id, region)
                _instance_region_cache[instance_id] = region
                return region
        except Exception:
            continue

    # Fallback: try EC2 describe (works for i-xxx, not mi-xxx)
    if instance_id.startswith("i-"):
        for region in regions:
            try:
                ec2 = boto3.client("ec2", region_name=region)
                resp = ec2.describe_instances(InstanceIds=[instance_id])
                if resp.get("Reservations"):
                    logger.info("Discovered instance %s in region %s (via EC2)", instance_id, region)
                    _instance_region_cache[instance_id] = region
                    return region
            except Exception:
                continue

    logger.warning("Could not discover region for instance %s", instance_id)
    return ""


def run_ssm_diagnostics(instance_id, commands, timeout=60, region=None):
    """Execute commands on an instance via SSM. Returns combined output string."""
    region = region or os.environ.get("SSM_REGION", "us-east-1")

    ssm = boto3.client("ssm", region_name=region)

    script_lines = ["#!/bin/bash", "set +e"]
    for idx, cmd in enumerate(commands, 1):
        script_lines.append(f"echo '===STEP {idx}==='")
        # Pipe each command through head to cap output per step (avoid one verbose
        # command like 'systemctl status' consuming the entire output budget)
        script_lines.append(f"{{ {cmd} ; }} 2>&1 | head -30")
        script_lines.append("")
    script = "\n".join(script_lines)

    logger.info("SSM sending command to %s (%d commands)", instance_id, len(commands))

    try:
        response = ssm.send_command(
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

    time.sleep(2)
    max_attempts = 30
    for attempt in range(max_attempts):
        try:
            result = ssm.get_command_invocation(
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
                logger.info("SSM command completed: status=%s, output_len=%d", status, len(output))
                if len(output) > 8000:
                    output = output[:8000] + "\n... (truncated)"
                return output

        except ssm.exceptions.InvocationDoesNotExist:
            pass
        except Exception:
            logger.exception("SSM get_command_invocation error (attempt %d)", attempt)

        time.sleep(3)

    return "(SSM timed out waiting for result)"


def _run_pre_upgrade_on_instances(instances, commands):
    """Run commands on each instance via SSM. Returns list of {instance_name, output}."""
    if not commands:
        return []

    results = []
    for inst in instances:
        inst_name = inst.get("name", "unknown")
        inst_id = inst.get("id", "")
        if not inst_id:
            logger.warning("No instance_id for %s, skipping SSM", inst_name)
            results.append({"instance_name": inst_name, "output": "(no instance_id, skipped)"})
            continue

        inst_region = inst.get("region", "")
        if not inst_region and inst_id:
            inst_region = _discover_instance_region(inst_id)
        inst_region = inst_region or os.environ.get("SSM_REGION", "us-east-1")
        logger.info("Running SSM commands on %s (%s) in %s", inst_name, inst_id, inst_region)
        try:
            output = run_ssm_diagnostics(inst_id, commands, timeout=120, region=inst_region)
        except Exception as e:
            output = f"(SSM error: {e})"
            logger.error("SSM failed for %s: %s", inst_name, e)

        results.append({"instance_name": inst_name, "output": output})

    return results


# =============================================================================
# Teams Card Builders
# =============================================================================

def _build_summary_card(
    chain, current_ver, latest_ver, instances, page_url, page_id,
    post_upgrade_commands, parent_msg, service_url, channel_id,
    pre_results,
):
    """Build the short Teams Adaptive Card that links to the upgrade plan on GitHub."""

    def _text(text, **kwargs):
        block = {"type": "TextBlock", "text": str(text), "wrap": True}
        block.update(kwargs)
        return block

    instance_names = ", ".join(i["name"] for i in instances) if instances else "—"
    pre_count = len(pre_results)
    pre_summary = (
        f"Pre-upgrade steps run on {pre_count} instance(s)."
        if pre_count else "No pre-upgrade steps executed."
    )

    body = [
        _text("\U0001f4cb Upgrade Plan Ready", size="Large", weight="Bolder"),
        _text(
            f"**Chain:** {chain.capitalize()}  |  "
            f"**Version:** {current_ver} \u2192 **{latest_ver}**",
        ),
        _text(f"**Instances:** {instance_names}", isSubtle=True),
        _text(pre_summary, separator=True),
        _text(
            "\u26a0\ufe0f **Upgrade Steps** must be performed manually — see GitHub for details.",
            color="attention",
        ),
        _text(
            datetime.now(tz=timezone.utc).strftime("Generated %Y-%m-%d %H:%M UTC"),
            isSubtle=True,
            size="Small",
        ),
    ]

    actions = []
    if page_url:
        actions.append({
            "type": "Action.OpenUrl",
            "title": "\U0001f4c4 View Upgrade Plan",
            "url": page_url,
        })

    if post_upgrade_commands:
        actions.append({
            "type": "Action.Submit",
            "title": "\u2705 Run Post-Upgrade Verification",
            "data": {
                "action_type":           "run_post_upgrade",
                "github_url":            page_url or "",
                "instances":             instances,
                "post_upgrade_commands": post_upgrade_commands,
                "chain":                 chain,
                "current_ver":           current_ver,
                "latest_ver":            latest_ver,
                "parent_message_id":     parent_msg,
                "service_url":           service_url,
                "channel_id":            channel_id,
            },
        })

    if actions:
        body.append({"type": "ActionSet", "actions": actions})

    return {
        "$schema": "http://adaptivecards.io/schemas/adaptive-card.json",
        "type": "AdaptiveCard",
        "version": "1.4",
        "body": body,
    }


def _build_verification_card(chain, current_ver, latest_ver, instances, results):
    """Build the Teams Adaptive Card summarizing post-upgrade verification results."""

    def _text(text, **kwargs):
        block = {"type": "TextBlock", "text": str(text), "wrap": True}
        block.update(kwargs)
        return block

    instance_names = ", ".join(i["name"] for i in instances) if instances else "—"
    success_count = sum(1 for r in results if "(SSM error" not in r.get("output", ""))

    body = [
        _text("\u2705 Post-Upgrade Verification Complete", size="Large", weight="Bolder"),
        _text(
            f"**Chain:** {chain.capitalize()}  |  **Version:** {current_ver} \u2192 {latest_ver}",
        ),
        _text(f"**Instances:** {instance_names}", isSubtle=True),
        _text(
            f"{success_count}/{len(results)} instances verified successfully.",
            separator=True,
            weight="Bolder",
        ),
    ]

    for r in results:
        inst_name = r.get("instance_name", "unknown")
        output = r.get("output", "")
        short_output = output[:300].replace("\n", "  ").strip()
        status_icon = "\u274c" if "(SSM error" in output else "\u2705"
        body.append(_text(f"{status_icon} **{inst_name}**"))
        if short_output:
            body.append(_text(f"`{short_output}`", isSubtle=True, size="Small"))

    body.append(_text(
        datetime.now(tz=timezone.utc).strftime("Verified %Y-%m-%d %H:%M UTC"),
        isSubtle=True,
        size="Small",
        separator=True,
    ))

    return {
        "$schema": "http://adaptivecards.io/schemas/adaptive-card.json",
        "type": "AdaptiveCard",
        "version": "1.4",
        "body": body,
    }


# =============================================================================
# Bot Framework Thread Reply
# =============================================================================

_anthropic_secret_cache = None


def _load_anthropic_secret():
    """Load the Anthropic secret JSON (cached)."""
    global _anthropic_secret_cache, _anthropic_api_key
    if _anthropic_secret_cache is not None:
        return _anthropic_secret_cache

    secret_arn = os.environ.get("ANTHROPIC_SECRET_ARN", "")
    if not secret_arn:
        return {}

    try:
        resp = secrets_client.get_secret_value(SecretId=secret_arn)
        raw = resp["SecretString"]
        try:
            _anthropic_secret_cache = json.loads(raw)
        except json.JSONDecodeError:
            _anthropic_secret_cache = {"api_key": raw.strip()}
        return _anthropic_secret_cache
    except Exception:
        logger.exception("Failed to load Anthropic secret")
        return {}


def _get_anthropic_key():
    """Get Anthropic API key from Secrets Manager (cached)."""
    global _anthropic_api_key
    if _anthropic_api_key is not None:
        return _anthropic_api_key

    secret = _load_anthropic_secret()
    _anthropic_api_key = secret.get("api_key", "") or secret.get("key", "")
    if _anthropic_api_key:
        logger.info("Anthropic API key loaded (length=%d)", len(_anthropic_api_key))
    return _anthropic_api_key or None


_github_token_cache = None


def _get_github_token():
    """Get GitHub token for private repo access.

    Tries dedicated secret (GITHUB_SECRET_ARN) first, then falls back to
    the Anthropic secret's github_token field for backward compatibility.
    """
    global _github_token_cache
    if _github_token_cache is not None:
        return _github_token_cache

    # Try dedicated GitHub secret
    github_secret_arn = os.environ.get("GITHUB_SECRET_ARN", "")
    if github_secret_arn:
        try:
            resp = secrets_client.get_secret_value(SecretId=github_secret_arn)
            raw = resp["SecretString"]
            try:
                secret = json.loads(raw)
                _github_token_cache = secret.get("github_token", "") or secret.get("token", "") or raw.strip()
            except (json.JSONDecodeError, TypeError):
                _github_token_cache = raw.strip()
            if _github_token_cache:
                logger.info("GitHub token loaded from GITHUB_SECRET_ARN (length=%d)", len(_github_token_cache))
                return _github_token_cache
        except Exception as e:
            logger.warning("Failed to load GITHUB_SECRET_ARN: %s", e)

    # Fallback: Anthropic secret
    _github_token_cache = _load_anthropic_secret().get("github_token", "")
    return _github_token_cache


def _call_claude(api_key, system_prompt, user_message):
    """Call the Anthropic Messages API."""
    payload = {
        "model": CLAUDE_MODEL,
        "max_tokens": CLAUDE_MAX_TOKENS,
        "system": system_prompt,
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

    with urllib.request.urlopen(req, timeout=60) as response:
        resp_data = json.loads(response.read().decode("utf-8"))

    content = resp_data.get("content", [])
    texts = [block["text"] for block in content if block.get("type") == "text"]
    return "\n".join(texts)


def _get_bot_config(service_url=None, channel_id=None):
    """Get Bot Framework credentials from Secrets Manager (cached)."""
    global _bot_config
    if _bot_config is None:
        secret_arn = os.environ.get("TEAMS_BOT_SECRET_ARN", "")
        if not secret_arn:
            return None
        try:
            resp = secrets_client.get_secret_value(SecretId=secret_arn)
            _bot_config = json.loads(resp["SecretString"])
        except Exception:
            logger.exception("Failed to load bot config")
            return None

    config = dict(_bot_config)
    if service_url:
        config["service_url"] = service_url
    if channel_id:
        config["channel_id"] = channel_id
    return config


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
        "client_id":     config["bot_app_id"],
        "client_secret": config["bot_app_password"],
        "scope":         "https://api.botframework.com/.default",
        "grant_type":    "client_credentials",
    }).encode()

    req = urllib.request.Request(token_url, data=token_data, method="POST")
    with urllib.request.urlopen(req, timeout=10) as resp:
        token_resp = json.loads(resp.read())
        _bot_token = token_resp["access_token"]
        _bot_token_expires = time.time() + token_resp.get("expires_in", 3600)
        return _bot_token


def reply_in_thread(parent_message_id, card_content, service_url=None, channel_id=None):
    """Reply in a Teams thread via Bot Framework API."""
    config = _get_bot_config(service_url=service_url, channel_id=channel_id)
    if not config:
        raise RuntimeError("Bot config not available")

    token = _get_bot_token()
    if not token:
        raise RuntimeError("Bot token not available")

    chan = config["channel_id"]
    svc_url = config.get("service_url", "https://smba.trafficmanager.net/teams/")

    thread_conv_id = f"{chan};messageid={parent_message_id}"
    url = f"{svc_url}v3/conversations/{thread_conv_id}/activities"

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
        logger.info("Thread reply sent: id=%s", result.get("id"))


def post_channel_message(card_content, service_url=None, channel_id=None):
    """Post a new message to the channel (fallback when no parent_message_id)."""
    config = _get_bot_config(service_url=service_url, channel_id=channel_id)
    if not config:
        raise RuntimeError("Bot config not available")

    token = _get_bot_token()
    chan = config["channel_id"]
    svc_url = config.get("service_url", "https://smba.trafficmanager.net/teams/")

    url = f"{svc_url}v3/conversations/{chan}/activities"
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
        logger.info("Channel message sent: id=%s", result.get("id"))


# =============================================================================
# Lambda Handlers
# =============================================================================

def lambda_handler(event, context):
    """Dispatch to upgrade plan or post-upgrade verification handler."""
    action = event.get("action_type", "upgrade_plan")
    if action == "run_post_upgrade":
        return _handle_post_upgrade_verification(event)
    return _handle_upgrade_plan(event)


def _handle_upgrade_plan(event):
    """Main upgrade plan pipeline: fetch → Claude → SSM → Notion → Teams."""
    alertname   = event.get("alertname", "")
    chain       = CHAIN_ALIASES.get(event.get("chain", "").lower(), event.get("chain", "").lower())
    instances   = event.get("instances", [])
    labels      = event.get("labels", {})
    parent_msg  = event.get("parent_message_id", "")
    service_url = event.get("service_url", "")
    channel_id  = event.get("channel_id", "")

    # Version hints from button data (avoid AMP round-trip when available)
    current_ver_hint = event.get("current_ver", "")
    latest_ver_hint  = event.get("latest_ver", "")

    # Pick a representative instance for AMP queries (first one)
    first_instance = instances[0]["name"] if instances else event.get("instance", "")

    logger.info(
        "Upgrade analyzer started: alertname=%s chain=%s instances=%s parent_msg=%s",
        alertname, chain, [i["name"] for i in instances], parent_msg,
    )

    # ── Phase 1: Version discovery ────────────────────────────────────────────
    try:
        current_ver, latest_ver = _get_versions(
            chain, first_instance, labels, alertname,
            current_ver_hint=current_ver_hint,
            latest_ver_hint=latest_ver_hint,
        )
    except Exception:
        logger.exception("Version discovery failed")
        current_ver = current_ver_hint or "unknown"
        latest_ver  = latest_ver_hint  or "unknown"

    logger.info("Versions: %s → %s", current_ver, latest_ver)

    # ── Phase 2: GitHub release notes + internal validator-context docs ──────
    repos = _get_repos_for_chain(chain, alertname)
    release_notes_parts = []
    for repo in repos:
        # Extract the repo-specific version from compound strings like "Besu 26.2.0 / Teku 26.3.0"
        repo_current_ver = _extract_version_tag(repo, current_ver)
        notes = _fetch_releases(repo, count=15, since_version=repo_current_ver)
        if notes:
            release_notes_parts.append(f"## {repo}\n\n{notes}")

    internal_context = _fetch_validator_context(chain)
    if internal_context:
        release_notes_parts.append(internal_context)

    release_notes = "\n\n".join(release_notes_parts) if release_notes_parts else "No release notes available."
    logger.info("Fetched release notes + internal context (%d chars)", len(release_notes))

    # ── Phase 3: Claude upgrade plan ─────────────────────────────────────────
    try:
        plan = _generate_upgrade_plan(chain, instances, current_ver, latest_ver, release_notes, alertname)
    except Exception:
        logger.exception("Claude upgrade plan generation failed")
        plan = {
            "summary": f"Upgrade {chain} from {current_ver} to {latest_ver}",
            "breaking_changes": [],
            "pre_upgrade_steps": [],
            "upgrade_steps": [{"step": "1", "description": "Follow official upgrade documentation", "command": ""}],
            "post_upgrade_steps": [{"step": "1", "description": "Verify node health", "command": ""}],
            "rollback_steps": ["Restore previous binary", "Restart service"],
            "estimated_downtime": "Unknown",
            "notes": "Automated plan generation failed. Please consult the release notes manually.",
        }

    # ── Phase 4a: SSM pre-upgrade steps ──────────────────────────────────────
    pre_cmds = [
        s["command"] for s in plan.get("pre_upgrade_steps", [])
        if s.get("command", "").strip()
    ]
    if pre_cmds:
        logger.info("Running %d pre-upgrade commands on %d instance(s)", len(pre_cmds), len(instances))
        pre_results = _run_pre_upgrade_on_instances(instances, pre_cmds)
    else:
        pre_results = []

    # ── Phase 4a-2: Analyze pre-upgrade results per node ────────────────────
    readiness_analysis = ""
    if pre_results:
        try:
            api_key = _get_anthropic_key()
            if api_key:
                readiness_analysis = _analyze_pre_upgrade_results(
                    api_key, chain, current_ver, latest_ver, plan, pre_results
                )
                logger.info("Readiness analysis generated (%d chars)", len(readiness_analysis))
        except Exception:
            logger.exception("Readiness analysis failed")

    # ── Phase 4b: Push upgrade plan to GitHub ────────────────────────────────
    page_url = None
    page_id = None
    github_token = _get_github_token()

    if github_token:
        md_content = _build_upgrade_plan_markdown(
            plan, pre_results, instances, chain, current_ver, latest_ver, alertname,
            readiness_analysis=readiness_analysis,
        )
        # Filename: sanitize version strings for filesystem
        safe_ver = f"{current_ver}_to_{latest_ver}".replace(" ", "-").replace("/", "-")
        filename = f"{safe_ver}.md"
        commit_msg = f"chore({chain}): upgrade plan {current_ver} → {latest_ver}"

        page_url = _push_to_github(github_token, chain, filename, md_content, commit_msg)
        if page_url:
            page_id = "github"
            logger.info("Upgrade plan pushed to GitHub: %s", page_url)
        else:
            logger.warning("GitHub push failed — upgrade plan will only be in Teams")
    else:
        logger.warning("No GitHub token configured — skipping GitHub push")

    # ── Phase 4c: Teams short card ────────────────────────────────────────────
    post_cmds = [
        s["command"] for s in plan.get("post_upgrade_steps", [])
        if s.get("command", "").strip()
    ]

    card = _build_summary_card(
        chain=chain,
        current_ver=current_ver,
        latest_ver=latest_ver,
        instances=instances,
        page_url=page_url,
        page_id=page_id,
        post_upgrade_commands=post_cmds,
        parent_msg=parent_msg,
        service_url=service_url,
        channel_id=channel_id,
        pre_results=pre_results,
    )

    try:
        if parent_msg:
            reply_in_thread(parent_msg, card, service_url=service_url, channel_id=channel_id)
            logger.info("Upgrade plan summary sent as thread reply")
        else:
            post_channel_message(card, service_url=service_url, channel_id=channel_id)
            logger.info("Upgrade plan summary sent as new channel message (no parent_message_id)")
    except Exception:
        logger.exception("Failed to send upgrade plan to Teams")
        raise

    return {
        "status": "ok",
        "chain": chain,
        "current": current_ver,
        "latest": latest_ver,
        "notion_page_url": page_url,
    }


def _handle_post_upgrade_verification(event):
    """Run post-upgrade verification on each instance and update Notion + Teams."""
    notion_page_id    = event.get("notion_page_id", "")
    instances         = event.get("instances", [])
    post_cmds         = event.get("post_upgrade_commands", [])
    chain             = event.get("chain", "")
    current_ver       = event.get("current_ver", "")
    latest_ver        = event.get("latest_ver", "")
    parent_msg        = event.get("parent_message_id", "")
    service_url       = event.get("service_url", "")
    channel_id        = event.get("channel_id", "")

    logger.info(
        "Post-upgrade verification started: chain=%s instances=%s",
        chain, [i["name"] for i in instances],
    )

    # Run verification commands via SSM
    results = _run_pre_upgrade_on_instances(instances, post_cmds)

    # Append results to Notion page
    token = _get_notion_token()
    if token and notion_page_id:
        now = datetime.now(tz=timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
        verif_blocks = [
            _notion_divider(),
            _notion_heading("✅ Post-Upgrade Verification Results"),
            _notion_paragraph(f"Executed: {now}"),
        ]
        for r in results:
            inst_name = r.get("instance_name", "unknown")
            output = r.get("output", "(no output)")
            verif_blocks.append(_notion_paragraph(f"Instance: {inst_name}"))
            verif_blocks.append(_notion_code(output[:2000]))

        try:
            _notion_append_blocks(token, notion_page_id, verif_blocks)
            logger.info("Appended verification results to Notion page: %s", notion_page_id)
        except Exception:
            logger.exception("Failed to append verification results to Notion")

    # Build and send verification card
    card = _build_verification_card(chain, current_ver, latest_ver, instances, results)

    try:
        if parent_msg:
            reply_in_thread(parent_msg, card, service_url=service_url, channel_id=channel_id)
            logger.info("Verification summary sent as thread reply")
        else:
            post_channel_message(card, service_url=service_url, channel_id=channel_id)
    except Exception:
        logger.exception("Failed to send verification summary to Teams")
        raise

    return {
        "status": "ok",
        "verified_instances": len(results),
    }
