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
    """Update the Notion page for a chain with latest knowledge."""
    token = _get_notion_token()
    if not token:
        logger.warning("No Notion token, skipping Notion update")
        return

    page_id = NOTION_CHAIN_PAGES.get(chain)
    if not page_id:
        logger.warning("No Notion page ID for chain: %s", chain)
        return

    now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")

    # Clear existing content blocks
    _notion_clear_blocks(token, page_id)

    # Build new content blocks
    blocks = []

    # Last updated timestamp
    blocks.append(_notion_callout(f"Last updated: {now}", "🕐"))

    # Static Knowledge section
    from lambda_rca_knowledge import CHAIN_KNOWLEDGE  # noqa: this won't work in Lambda
    # Instead, import from rca-analyzer's knowledge - but we can't cross-reference Lambdas
    # So we just write the dynamic content here

    # Operational Updates
    blocks.append(_notion_heading("Operational Updates"))
    for line in (knowledge or "No updates available.").split("\n"):
        line = line.strip()
        if not line:
            continue
        if line.startswith("BREAKING") or line.startswith("KNOWN") or line.startswith("NEW") or line.startswith("RECOMMENDED"):
            blocks.append(_notion_heading(line.rstrip(":"), level=3))
        elif line.startswith("- "):
            blocks.append(_notion_bullet(line[2:]))
        else:
            blocks.append(_notion_paragraph(line))

    blocks.append(_notion_divider())

    # Latest Releases
    blocks.append(_notion_heading("Latest Releases"))
    if releases_text:
        for line in releases_text[:3000].split("\n"):
            line = line.strip()
            if not line:
                continue
            if line.startswith("Release:"):
                blocks.append(_notion_heading(line, level=3))
            elif line.startswith("- ") or line.startswith("* "):
                blocks.append(_notion_bullet(line[2:]))
            else:
                blocks.append(_notion_paragraph(line[:2000]))
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


def _notion_callout(text, emoji="💡"):
    return {"object": "block", "type": "callout", "callout": {
        "icon": {"emoji": emoji},
        "rich_text": [{"text": {"content": text[:2000]}}]
    }}


def _notion_divider():
    return {"object": "block", "type": "divider", "divider": {}}
