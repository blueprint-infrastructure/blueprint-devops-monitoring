"""
Lambda function: Upgrade Plan Analyzer for Version Drift Alerts

Triggered by the "📋 Upgrade Plan" button on Teams version-drift alert cards.
Fetches GitHub release notes for the version range, calls Claude to generate
a structured upgrade plan, and replies in the Teams thread via Bot Framework.

Architecture:
    bot-endpoint Lambda -> This Lambda (async)
        Phase 1: Discover current/latest versions (labels → AMP → GitHub)
        Phase 2: Fetch GitHub release notes for the version range
        Phase 3: Claude API → structured JSON upgrade plan
        Phase 4: Bot Framework API → Adaptive Card thread reply

Environment variables:
    ANTHROPIC_SECRET_ARN: Secrets Manager ARN — JSON with "api_key" (required)
                          and optional "github_token" for validator-context access
    TEAMS_BOT_SECRET_ARN: Secrets Manager ARN for Bot Framework credentials
    AMP_WORKSPACE_ID: Amazon Managed Prometheus workspace ID
    AMP_REGION: AMP region (default us-east-1)
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

# Cached secrets / tokens
_anthropic_api_key = None
_bot_config = None
_bot_token = None
_bot_token_expires = 0

CLAUDE_MODEL = "claude-sonnet-4-6"
CLAUDE_MAX_TOKENS = 2048

# =============================================================================
# Chain Configuration
# =============================================================================

VALIDATOR_CONTEXT_REPO = "blueprint-infrastructure/validator-context"

CHAIN_REPOS = {
    "avalanche": ["ava-labs/avalanchego"],
    "solana":    ["anza-xyz/agave"],
    "algorand":  ["algorand/go-algorand"],
    "ethereum":  ["hyperledger/besu", "Consensys/teku"],  # filtered by alertname
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
        "Config dir: ~/.avalanchego/. "
        "Binary: /usr/local/bin/avalanchego. "
        "Restart: systemctl restart avalanchego. "
        "Verify: avalanchego --version && curl -s -X POST --data '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"info.isBootstrapped\",\"params\":{\"chain\":\"X\"}}' -H 'content-type:application/json;' http://127.0.0.1:9650/ext/info"
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
        "Services: besu (execution layer) + teku (consensus layer). "
        "Rolling upgrade order: upgrade teku first, then besu. "
        "Besu restart: systemctl restart besu. "
        "Teku restart: systemctl restart teku. "
        "Verify: curl -s http://localhost:5051/eth/v1/node/syncing; curl -s http://localhost:8545 -X POST -H 'Content-Type: application/json' -d '{\"jsonrpc\":\"2.0\",\"method\":\"eth_syncing\",\"params\":[],\"id\":1}'"
    ),
    "audius": (
        "Deployed via docker-compose + optional watchtower auto-upgrade. "
        "Manual upgrade: docker compose pull && docker compose up -d. "
        "Verify: docker compose ps; curl http://localhost/health_check."
    ),
    "canton": (
        "Canton Enterprise node. "
        "Check official release docs for database migration scripts before upgrading. "
        "Restart: docker compose down && docker compose up -d. "
        "Verify: docker compose logs --tail=50."
    ),
}

# =============================================================================
# Phase 1: Version Discovery
# =============================================================================

def _get_versions(chain, instance, labels, alertname=""):
    """Discover current and latest version strings via labels → AMP → GitHub.

    Returns (current_ver, latest_ver) — either may be "unknown" if not found.
    """
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
        # For ethereum, pick the right sub-client metric
        if chain == "ethereum":
            if "Teku" in alertname:
                cur_metric = "ethereum_teku_version"
                lat_metric = "ethereum_teku_latest_version"
            # else stays as besu defaults
        try:
            current_ver = _query_amp_version_label(workspace_id, region, cur_metric, instance)
            latest_ver = _query_amp_version_label(workspace_id, region, lat_metric, instance)
            logger.info("Versions from AMP: current=%s latest=%s", current_ver, latest_ver)
        except Exception as e:
            logger.warning("AMP version query failed: %s", e)

    # Try 3: GitHub latest release as fallback for latest_ver
    repos = _get_repos_for_chain(chain, alertname)
    if not latest_ver and repos:
        try:
            latest_ver = _get_latest_tag(repos[0])
            logger.info("Latest version from GitHub: %s", latest_ver)
        except Exception as e:
            logger.warning("GitHub latest tag fetch failed: %s", e)

    return current_ver or "unknown", latest_ver or "unknown"


def _query_amp_version_label(workspace_id, region, metric_name, instance):
    """Query AMP for a version metric and extract the 'version' label value.

    Returns empty string if not found.
    """
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

    # Version strings are usually in metric labels
    metric_labels = results[0].get("metric", {})
    return (
        metric_labels.get("version", "")
        or metric_labels.get("value", "")
        or ""
    )


# =============================================================================
# Phase 2: GitHub Release Notes
# =============================================================================

def _get_repos_for_chain(chain, alertname=""):
    """Return the list of GitHub repos for this chain/alertname."""
    repos = CHAIN_REPOS.get(chain, [])
    if chain == "ethereum" and len(repos) == 2:
        # Filter to the relevant client
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
    """Fetch recent GitHub releases, optionally filtering to those after since_version.

    Returns combined release notes as a string (truncated per release).
    """
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
        # Skip releases older than current_ver if we have version info
        if since_version and since_version != "unknown" and tag:
            # Simple string comparison — works for semver-like "v1.2.3" tags
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
    """Fetch internal upgrade docs from blueprint-infrastructure/validator-context (best-effort).

    Reads {chain}/wiki/upgrade.md and any non-empty files in {chain}/scripts/.
    Silently skips missing files (404) or when no GitHub token is configured.
    """
    github_token = _get_github_token()
    if not github_token:
        return ""

    headers = {
        "Authorization": f"Bearer {github_token}",
        "Accept": "application/vnd.github+json",
        "User-Agent": "staking-alert-upgrade-analyzer",
    }
    results = []

    # 1. {chain}/wiki/upgrade.md
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

    # 2. {chain}/scripts/ — fetch non-empty script files
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
"""


def _generate_upgrade_plan(chain, instance, current_ver, latest_ver, release_notes, alertname=""):
    """Call Claude to generate a structured upgrade plan JSON."""
    api_key = _get_anthropic_key()
    if not api_key:
        raise RuntimeError("Anthropic API key not available")

    chain_ctx = CHAIN_UPGRADE_CONTEXT.get(chain, "No chain-specific context available.")

    user_message = f"""Chain: {chain}
Alert: {alertname}
Instance: {instance}
Current version: {current_ver}
Target version: {latest_ver}

Operational context:
{chain_ctx}

GitHub release notes ({current_ver} → {latest_ver}):
{release_notes[:8000]}

Generate the upgrade plan JSON now."""

    raw = _call_claude(api_key, UPGRADE_SYSTEM_PROMPT, user_message)

    # Strip accidental markdown code fences
    cleaned = raw.strip()
    if cleaned.startswith("```"):
        lines = cleaned.split("\n")
        lines = [l for l in lines if not l.strip().startswith("```")]
        cleaned = "\n".join(lines).strip()

    try:
        plan = json.loads(cleaned)
    except json.JSONDecodeError as e:
        logger.error("Claude returned non-JSON: %s", raw[:500])
        # Return a minimal fallback plan
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
# Phase 4: Adaptive Card Build + Teams Reply
# =============================================================================

def _build_upgrade_card(alertname, instance, chain, current_ver, latest_ver, plan):
    """Build Adaptive Card content for the upgrade plan."""

    def _text(text, **kwargs):
        block = {"type": "TextBlock", "text": str(text), "wrap": True}
        block.update(kwargs)
        return block

    body = [
        _text("\U0001f4cb Upgrade Plan", size="Large", weight="Bolder"),
        _text(f"**Alert:** {alertname}  |  **Instance:** {instance}  |  **Chain:** {chain}"),
        _text(
            f"\U0001f4e6 {current_ver}  \u2192  **{latest_ver}**",
            color="accent",
            size="Medium",
        ),
        _text(
            datetime.now(tz=timezone.utc).strftime("Generated %Y-%m-%d %H:%M UTC"),
            isSubtle=True,
            size="Small",
        ),
    ]

    # Summary
    body.append(_text("\U0001f4dd Summary", weight="Bolder", separator=True))
    body.append(_text(plan.get("summary", "—")))

    # Breaking changes
    breaking = plan.get("breaking_changes", [])
    body.append(_text("\u26a0\ufe0f Breaking Changes", weight="Bolder", separator=True))
    if breaking:
        for change in breaking:
            body.append(_text(f"\u2022 {change}", color="attention"))
    else:
        body.append(_text("None", color="good"))

    # Pre-upgrade steps
    pre_steps = plan.get("pre_upgrade_steps", [])
    if pre_steps:
        body.append(_text("\U0001f527 Pre-Upgrade Steps", weight="Bolder", separator=True))
        for s in pre_steps:
            step_text = f"**{s.get('step', '')}. {s.get('description', '')}**"
            if s.get("command"):
                step_text += f"\n`{s['command']}`"
            body.append(_text(step_text))

    # Upgrade steps
    upgrade_steps = plan.get("upgrade_steps", [])
    if upgrade_steps:
        body.append(_text("\u2b06\ufe0f Upgrade Steps", weight="Bolder", separator=True))
        for s in upgrade_steps:
            step_text = f"**{s.get('step', '')}. {s.get('description', '')}**"
            if s.get("command"):
                step_text += f"\n`{s['command']}`"
            body.append(_text(step_text))

    # Post-upgrade verification
    post_steps = plan.get("post_upgrade_steps", [])
    if post_steps:
        body.append(_text("\u2705 Post-Upgrade Verification", weight="Bolder", separator=True))
        for s in post_steps:
            step_text = f"**{s.get('step', '')}. {s.get('description', '')}**"
            if s.get("command"):
                step_text += f"\n`{s['command']}`"
            body.append(_text(step_text))

    # Rollback
    rollback = plan.get("rollback_steps", [])
    if rollback:
        body.append(_text("\u21a9\ufe0f Rollback Steps", weight="Bolder", separator=True))
        for s in rollback:
            body.append(_text(f"\u2022 {s}"))

    # Estimated downtime + notes
    downtime = plan.get("estimated_downtime", "")
    if downtime:
        body.append(_text(f"\u23f1 Estimated downtime: **{downtime}**", separator=True))

    notes = plan.get("notes", "")
    if notes:
        body.append(_text(notes, isSubtle=True))

    body.append(_text(
        "\u2500" * 20 + "\n\U0001f916 Generated via GitHub releases + Claude API",
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
    """Load the Anthropic secret JSON (cached). Contains api_key and optional github_token."""
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


def _get_github_token():
    """Get GitHub token for private repo access (optional, from same secret as Anthropic key)."""
    return _load_anthropic_secret().get("github_token", "")


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
    """Get Bot Framework credentials from Secrets Manager (cached).

    If service_url or channel_id are provided, they override the stored values
    (the stored values are the defaults from the secret, but Teams sends the
    actual endpoint in the activity).
    """
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

    # Build a copy with overrides
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
        logger.info("Upgrade plan thread reply sent: id=%s", result.get("id"))


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
        logger.info("Upgrade plan channel message sent: id=%s", result.get("id"))


# =============================================================================
# Lambda Handler
# =============================================================================

def lambda_handler(event, context):
    """Main entry point — 4-phase upgrade plan pipeline."""
    alertname   = event.get("alertname", "")
    instance    = event.get("instance", "")
    instance_id = event.get("instance_id", "")
    chain       = event.get("chain", "").lower()
    labels      = event.get("labels", {})
    parent_msg  = event.get("parent_message_id", "")
    service_url = event.get("service_url", "")
    channel_id  = event.get("channel_id", "")

    logger.info(
        "Upgrade analyzer started: alertname=%s instance=%s chain=%s parent_msg=%s",
        alertname, instance, chain, parent_msg,
    )

    # ── Phase 1: Version discovery ────────────────────────────────────────────
    try:
        current_ver, latest_ver = _get_versions(chain, instance, labels, alertname)
    except Exception:
        logger.exception("Version discovery failed")
        current_ver, latest_ver = "unknown", "unknown"

    logger.info("Versions: %s → %s", current_ver, latest_ver)

    # ── Phase 2: GitHub release notes + internal validator-context docs ──────
    repos = _get_repos_for_chain(chain, alertname)
    release_notes_parts = []
    for repo in repos:
        notes = _fetch_releases(repo, count=15, since_version=current_ver)
        if notes:
            release_notes_parts.append(f"## {repo}\n\n{notes}")

    internal_context = _fetch_validator_context(chain)
    if internal_context:
        release_notes_parts.append(internal_context)

    release_notes = "\n\n".join(release_notes_parts) if release_notes_parts else "No release notes available."
    logger.info("Fetched release notes + internal context (%d chars)", len(release_notes))

    # ── Phase 3: Claude upgrade plan ─────────────────────────────────────────
    try:
        plan = _generate_upgrade_plan(chain, instance, current_ver, latest_ver, release_notes, alertname)
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

    # ── Phase 4: Teams reply ──────────────────────────────────────────────────
    card = _build_upgrade_card(alertname, instance, chain, current_ver, latest_ver, plan)

    try:
        if parent_msg:
            reply_in_thread(parent_msg, card, service_url=service_url, channel_id=channel_id)
            logger.info("Upgrade plan sent as thread reply")
        else:
            post_channel_message(card, service_url=service_url, channel_id=channel_id)
            logger.info("Upgrade plan sent as new channel message (no parent_message_id)")
    except Exception:
        logger.exception("Failed to send upgrade plan to Teams")
        raise

    return {"status": "ok", "chain": chain, "current": current_ver, "latest": latest_ver}
