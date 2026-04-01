"""
Lambda function: Grafana Alert -> Teams (Bot Framework) + SES Email + RCA Trigger

Receives SNS notifications from Amazon Managed Grafana alerts,
posts to Microsoft Teams channel via Azure Bot Framework API (returns
a message_id for reply-in-thread), sends HTML email via SES for critical
alerts, and triggers the RCA Lambda for automated root cause analysis.

Architecture:
    AMG Alert -> SNS Topic -> This Lambda -> Bot Framework API (returns message_id)
                                          -> SES Email (critical only)
                                          -> RCA Lambda (async, reply-in-thread)

Environment variables:
    TEAMS_BOT_SECRET_ARN: Secrets Manager ARN for Bot Framework credentials
    TEAMS_WEBHOOK_URL: (fallback) Power Automate webhook URL
    ALERT_EMAIL_SENDER: SES verified sender address
    ALERT_EMAIL_RECIPIENTS: Comma-separated recipient addresses
    STAKING_ALERT_CRITICAL_TOPIC_ARN: Critical SNS topic ARN (triggers email)
    RCA_LAMBDA_FUNCTION_NAME: Name of the RCA analyzer Lambda function
"""

import json
import logging
import os
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone

import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

ses_client = boto3.client("ses")
lambda_client = boto3.client("lambda")
ssm_client = boto3.client("ssm")
secrets_client = boto3.client("secretsmanager")

# Cache: instance name -> SSM instance ID (populated on first use)
_instance_id_cache = {}

# Cache: Bot Framework credentials + token
_bot_config = None
_bot_token = None
_bot_token_expires = 0

SEVERITY_EMOJI = {
    "critical": "\U0001f534",  # red circle
    "high": "\U0001f7e0",      # orange circle
    "warning": "\U0001f7e1",   # yellow circle
}

STATUS_EMOJI = {
    "firing": "\U0001f525",    # fire
    "resolved": "\u2705",      # green check
}

SEVERITY_HTML_COLORS = {
    "critical": "#dc3545",
    "high": "#fd7e14",
    "warning": "#ffc107",
}

SEVERITY_COLORS = {
    "critical": "attention",
    "high": "warning",
    "warning": "accent",
}


# =============================================================================
# Main Handler
# =============================================================================

def lambda_handler(event, context):
    """Main Lambda handler - processes SNS records and posts to Teams."""
    critical_topic_arn = os.environ.get("STAKING_ALERT_CRITICAL_TOPIC_ARN", "")

    for record in event.get("Records", []):
        sns_data = record.get("Sns", {})
        sns_message = sns_data.get("Message", "{}")
        topic_arn = sns_data.get("TopicArn", "")
        logger.info("Received SNS message from %s: %s", topic_arn, sns_message[:500])

        try:
            alert_data = json.loads(sns_message)
        except json.JSONDecodeError:
            alert_data = {"message": sns_message}

        # Deduplicate alerts by instance
        unique_alerts = _deduplicate_alerts(alert_data.get("alerts", []))

        # Send to Teams via Bot Framework API (returns message_id)
        message_id = None
        card_content = build_adaptive_card_content(alert_data, unique_alerts)
        try:
            message_id = post_via_bot(card_content)
            logger.info("Posted via Bot Framework, message_id=%s", message_id)
        except Exception:
            logger.exception("Bot Framework post failed, trying webhook fallback")
            # Fallback to Power Automate webhook
            webhook_url = os.environ.get("TEAMS_WEBHOOK_URL", "")
            if webhook_url:
                try:
                    post_to_teams_webhook(webhook_url, _wrap_adaptive_card(card_content))
                except Exception:
                    logger.exception("Webhook fallback also failed")

        # Send email only for critical topic
        if topic_arn == critical_topic_arn:
            send_email(alert_data)

        # RCA is triggered on-demand via card buttons, not automatically

    return {"statusCode": 200, "body": "OK"}


def _deduplicate_alerts(alerts):
    """Deduplicate alerts by instance (Grafana sends one per expression ref)."""
    seen = set()
    unique = []
    for alert in alerts:
        instance = alert.get("labels", {}).get("instance", "")
        if instance not in seen:
            seen.add(instance)
            unique.append(alert)
    return unique


# =============================================================================
# Bot Framework API
# =============================================================================

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
        logger.info("Bot config loaded: app_id=%s", _bot_config.get("bot_app_id", "")[:8])
        return _bot_config
    except Exception:
        logger.exception("Failed to load bot config")
        return None


def _get_bot_token():
    """Get Bot Framework OAuth token (cached until expiry)."""
    import time
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
        logger.info("Bot token obtained, expires_in=%s", token_resp.get("expires_in"))
        return _bot_token


def post_via_bot(card_content):
    """Post an Adaptive Card to Teams via Bot Framework API. Returns message_id."""
    config = _get_bot_config()
    if not config:
        raise RuntimeError("Bot config not available")

    token = _get_bot_token()
    if not token:
        raise RuntimeError("Bot token not available")

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
        result = json.loads(resp.read())
        message_id = result.get("id")
        logger.info("Bot message sent: id=%s", message_id)
        return message_id


# =============================================================================
# Teams Webhook (Fallback)
# =============================================================================

def post_to_teams_webhook(webhook_url, card_payload):
    """POST Adaptive Card to Teams via Power Automate webhook (fallback)."""
    data = json.dumps(card_payload).encode("utf-8")
    req = urllib.request.Request(
        webhook_url, data=data,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=15) as response:
        logger.info("Webhook fallback response: %s", response.status)


def build_adaptive_card_content(alert_data, unique_alerts):
    """Build Adaptive Card content (body only) from Grafana alert data.

    Returns the card content dict (schema + body), NOT the webhook wrapper.
    Used by both Bot Framework and webhook (with different wrappers).
    """
    alerts = alert_data.get("alerts", [])

    # Plain text message (not Grafana structured)
    if not alerts and "message" in alert_data:
        return _build_simple_card_content(str(alert_data["message"]))

    status = alert_data.get("status", "unknown").lower()
    title = alert_data.get("title",
                alert_data.get("commonLabels", {}).get("alertname", "Grafana Alert"))
    common_labels = alert_data.get("commonLabels", {})
    severity = common_labels.get("severity", "warning")

    status_emoji = STATUS_EMOJI.get(status, "\u2139\ufe0f")
    severity_emoji = SEVERITY_EMOJI.get(severity, "\u2139\ufe0f")
    color = SEVERITY_COLORS.get(severity, "default")

    body = []

    # Header
    body.append({
        "type": "TextBlock",
        "size": "Large",
        "weight": "Bolder",
        "text": f"{status_emoji} {title}",
        "wrap": True,
        "style": "heading",
    })

    # Status + severity + count
    count = len(unique_alerts)
    body.append({
        "type": "TextBlock",
        "text": (
            f"**Status:** {status.upper()}  |  "
            f"**Severity:** {severity_emoji} {severity.upper()}  |  "
            f"**Instances:** {count}"
        ),
        "wrap": True,
        "color": color,
    })

    # Timestamp
    now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")
    body.append({
        "type": "TextBlock",
        "text": f"**Time:** {now}",
        "wrap": True,
        "isSubtle": True,
    })

    # Common description (show once, from first alert)
    if unique_alerts:
        first_ann = unique_alerts[0].get("annotations", {})
        desc = first_ann.get("description", "")

        # Strip "silence by running" instructions from description
        if desc:
            for marker in ["Alert auto-resolves", "If this is a planned", "silence by running"]:
                idx = desc.find(marker)
                if idx > 0:
                    desc = desc[:idx].rstrip(". ")
                    break

        if desc:
            body.append({
                "type": "TextBlock",
                "text": f"**Description:** {desc}",
                "wrap": True,
                "separator": True,
            })

    # Affected instances with inline RCA buttons (one row per instance)
    is_firing = alert_data.get("status", "").lower() == "firing"
    if unique_alerts:
        body.append({
            "type": "TextBlock",
            "text": "**Affected instances:**",
            "wrap": True,
            "separator": True,
            "weight": "Bolder",
        })

        for alert in unique_alerts:
            labels = alert.get("labels", {})
            annotations = alert.get("annotations", {})
            instance = labels.get("instance", "unknown")
            instance_id = labels.get("instance_id", "")
            chain = labels.get("chain", "")

            # Resolve instance_id if not in labels
            if not instance_id:
                instance_id = _resolve_instance_id(instance)

            chain_prefix = f"[{chain}] " if chain else ""

            # For firing alerts with a known instance_id: show instance + inline action buttons
            if is_firing and instance_id:
                alertname_label = labels.get("alertname", title)
                is_version_drift = "VersionDrift" in alertname_label

                instance_actions = [{
                    "type": "Action.Submit",
                    "title": "\U0001f50d Analyze",
                    "data": {
                        "action_type": "trigger_rca",
                        "alertname": alertname_label,
                        "instance": instance,
                        "instance_id": instance_id,
                        "chain": chain,
                        "severity": labels.get("severity", severity),
                        "description": annotations.get("description", ""),
                        "summary": annotations.get("summary", ""),
                        "runbook_url": annotations.get("runbook_url", ""),
                        "labels": labels,
                    },
                }]
                if is_version_drift:
                    instance_actions.append({
                        "type": "Action.Submit",
                        "title": "\U0001f4cb Upgrade Plan",
                        "data": {
                            "action_type": "upgrade_plan",
                            "alertname": alertname_label,
                            "instance": instance,
                            "instance_id": instance_id,
                            "chain": chain,
                            "labels": labels,
                        },
                    })

                body.append({
                    "type": "ColumnSet",
                    "columns": [
                        {
                            "type": "Column",
                            "width": "stretch",
                            "verticalContentAlignment": "Center",
                            "items": [{
                                "type": "TextBlock",
                                "text": f"{chain_prefix}**{instance}**",
                                "wrap": True,
                            }],
                        },
                        {
                            "type": "Column",
                            "width": "auto",
                            "items": [{
                                "type": "ActionSet",
                                "actions": instance_actions,
                            }],
                        },
                    ],
                })
            else:
                body.append({
                    "type": "TextBlock",
                    "text": f"- {chain_prefix}**{instance}**",
                    "wrap": True,
                })

    return _make_card_content(body)


def _build_simple_card_content(message):
    """Build a simple card content for non-structured messages."""
    body = [
        {
            "type": "TextBlock",
            "text": "Grafana Alert",
            "size": "Large",
            "weight": "Bolder",
        },
        {
            "type": "TextBlock",
            "text": message,
            "wrap": True,
        },
    ]
    return _make_card_content(body)


def _make_card_content(body):
    """Build Adaptive Card content dict (used by Bot Framework directly)."""
    return {
        "$schema": "http://adaptivecards.io/schemas/adaptive-card.json",
        "type": "AdaptiveCard",
        "version": "1.4",
        "body": body,
    }


def _wrap_adaptive_card(card_content):
    """Wrap card content in Power Automate webhook envelope (fallback only)."""
    return {
        "type": "message",
        "attachments": [
            {
                "contentType": "application/vnd.microsoft.card.adaptive",
                "contentUrl": None,
                "content": card_content,
            }
        ],
    }


# =============================================================================
# RCA Trigger
# =============================================================================

def _resolve_instance_id(instance_name):
    """Resolve an instance name to SSM instance ID.

    Checks the alert labels first, then falls back to querying SSM
    describe-instance-information to match by ComputerName or Name tag.
    Results are cached for the Lambda lifetime.
    """
    global _instance_id_cache

    if instance_name in _instance_id_cache:
        return _instance_id_cache[instance_name]

    # Build cache on first call — query all regions where nodes are deployed
    if not _instance_id_cache:
        ssm_regions = os.environ.get("SSM_REGIONS", "us-east-1,us-west-2,us-west-1,us-east-2").split(",")
        for region in ssm_regions:
            try:
                regional_client = boto3.client("ssm", region_name=region.strip())
                paginator = regional_client.get_paginator("describe_instance_information")
                for page in paginator.paginate():
                    for inst in page.get("InstanceInformationList", []):
                        inst_id = inst.get("InstanceId", "")
                        computer = inst.get("ComputerName", "")
                        name = inst.get("Name", "")
                        # Map by ComputerName (hostname)
                        if computer:
                            _instance_id_cache[computer] = inst_id
                            # Also map short name (e.g., "creator-5.theblueprint.xyz" -> "creator-5")
                            short = computer.split(".")[0]
                            if short != computer:
                                _instance_id_cache[short] = inst_id
                        # Map by Name tag (activation name)
                        if name:
                            _instance_id_cache[name] = inst_id
            except Exception:
                logger.exception("Failed to query SSM in region %s", region)
        logger.info("SSM instance cache built: %d entries across %d regions",
                    len(_instance_id_cache), len(ssm_regions))

    return _instance_id_cache.get(instance_name, "")


def trigger_rca(alert_data, unique_alerts, parent_message_id):
    """Trigger RCA Lambda asynchronously for each alert with instance_id."""
    rca_function = os.environ.get("RCA_LAMBDA_FUNCTION_NAME", "")
    if not rca_function:
        logger.info("RCA_LAMBDA_FUNCTION_NAME not set, skipping RCA trigger")
        return

    for alert in unique_alerts:
        labels = alert.get("labels", {})
        annotations = alert.get("annotations", {})
        instance_name = labels.get("instance", "")
        instance_id = labels.get("instance_id", "")

        # If instance_id not in labels, resolve from SSM
        if not instance_id and instance_name:
            instance_id = _resolve_instance_id(instance_name)
            if instance_id:
                logger.info("Resolved instance_id for %s: %s", instance_name, instance_id)

        if not instance_id:
            logger.info("No instance_id for %s, skipping RCA", instance_name)
            continue

        rca_payload = {
            "alertname": labels.get("alertname", ""),
            "instance": labels.get("instance", ""),
            "instance_id": instance_id,
            "chain": labels.get("chain", ""),
            "severity": labels.get("severity", ""),
            "status": "firing",
            "description": annotations.get("description", ""),
            "summary": annotations.get("summary", ""),
            "runbook_url": annotations.get("runbook_url", ""),
            "labels": labels,
            "parent_message_id": parent_message_id,
        }

        try:
            lambda_client.invoke(
                FunctionName=rca_function,
                InvocationType="Event",  # async
                Payload=json.dumps(rca_payload).encode("utf-8"),
            )
            logger.info("RCA triggered for %s (%s)", labels.get("instance", ""), instance_id)
        except Exception:
            logger.exception("Failed to trigger RCA for %s", labels.get("instance", ""))


# =============================================================================
# SES Email
# =============================================================================

def send_email(alert_data):
    """Send an HTML alert email via SES for critical alerts."""
    sender = os.environ.get("ALERT_EMAIL_SENDER", "")
    recipients_str = os.environ.get("ALERT_EMAIL_RECIPIENTS", "")

    if not sender or not recipients_str:
        logger.warning("SES email skipped: ALERT_EMAIL_SENDER or ALERT_EMAIL_RECIPIENTS not set")
        return

    recipients = [r.strip() for r in recipients_str.split(",") if r.strip()]
    if not recipients:
        return

    status = alert_data.get("status", "unknown").upper()
    title = alert_data.get("title",
                alert_data.get("commonLabels", {}).get("alertname", "Grafana Alert"))
    severity = alert_data.get("commonLabels", {}).get("severity", "critical")

    subject = f"[{status}] [{severity.upper()}] {title}"
    html_body = _build_email_html(alert_data)
    text_body = _build_email_text(alert_data)

    try:
        resp = ses_client.send_email(
            Source=sender,
            Destination={"ToAddresses": recipients},
            Message={
                "Subject": {"Data": subject, "Charset": "UTF-8"},
                "Body": {
                    "Html": {"Data": html_body, "Charset": "UTF-8"},
                    "Text": {"Data": text_body, "Charset": "UTF-8"},
                },
            },
        )
        logger.info("SES email sent: MessageId=%s, to=%s", resp["MessageId"], recipients)
    except Exception:
        logger.exception("Failed to send SES email")


def _build_email_html(alert_data):
    """Build an HTML email body from Grafana alert data."""
    alerts = alert_data.get("alerts", [])
    status = alert_data.get("status", "unknown").upper()
    title = alert_data.get("title",
                alert_data.get("commonLabels", {}).get("alertname", "Grafana Alert"))
    severity = alert_data.get("commonLabels", {}).get("severity", "critical")
    now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")

    color = SEVERITY_HTML_COLORS.get(severity, "#6c757d")
    status_color = "#dc3545" if status == "FIRING" else "#28a745"

    rows = ""
    for alert in alerts:
        labels = alert.get("labels", {})
        annotations = alert.get("annotations", {})
        alertname = labels.get("alertname", "")
        instance = labels.get("instance", "")
        summary = annotations.get("summary", "")
        description = annotations.get("description", "")
        runbook = annotations.get("runbook_url", "")

        rows += f"""
        <tr>
            <td style="padding:8px;border-bottom:1px solid #eee;"><strong>{alertname}</strong></td>
            <td style="padding:8px;border-bottom:1px solid #eee;">{instance}</td>
            <td style="padding:8px;border-bottom:1px solid #eee;">{summary}</td>
            <td style="padding:8px;border-bottom:1px solid #eee;">{description}</td>
            <td style="padding:8px;border-bottom:1px solid #eee;">{"<a href='" + runbook + "'>Runbook</a>" if runbook else ""}</td>
        </tr>"""

    return f"""<!DOCTYPE html>
<html>
<head><meta charset="UTF-8"></head>
<body style="font-family:Arial,sans-serif;margin:0;padding:20px;background:#f5f5f5;">
  <div style="max-width:700px;margin:0 auto;background:white;border-radius:8px;overflow:hidden;box-shadow:0 2px 4px rgba(0,0,0,0.1);">
    <div style="background:{color};padding:16px 24px;color:white;">
      <h2 style="margin:0;">{title}</h2>
    </div>
    <div style="padding:24px;">
      <p>
        <span style="background:{status_color};color:white;padding:4px 12px;border-radius:4px;font-weight:bold;">{status}</span>
        <span style="background:{color};color:white;padding:4px 12px;border-radius:4px;font-weight:bold;margin-left:8px;">{severity.upper()}</span>
        <span style="color:#666;margin-left:12px;">{now}</span>
      </p>
      <table style="width:100%;border-collapse:collapse;margin-top:16px;">
        <thead>
          <tr style="background:#f8f9fa;">
            <th style="padding:8px;text-align:left;border-bottom:2px solid #dee2e6;">Alert</th>
            <th style="padding:8px;text-align:left;border-bottom:2px solid #dee2e6;">Instance</th>
            <th style="padding:8px;text-align:left;border-bottom:2px solid #dee2e6;">Summary</th>
            <th style="padding:8px;text-align:left;border-bottom:2px solid #dee2e6;">Description</th>
            <th style="padding:8px;text-align:left;border-bottom:2px solid #dee2e6;">Runbook</th>
          </tr>
        </thead>
        <tbody>{rows}</tbody>
      </table>
    </div>
    <div style="padding:12px 24px;background:#f8f9fa;color:#666;font-size:12px;">
      Staking Infrastructure Monitoring
    </div>
  </div>
</body>
</html>"""


def _build_email_text(alert_data):
    """Build a plain-text email body (fallback)."""
    alerts = alert_data.get("alerts", [])
    status = alert_data.get("status", "unknown").upper()
    title = alert_data.get("title",
                alert_data.get("commonLabels", {}).get("alertname", "Grafana Alert"))
    severity = alert_data.get("commonLabels", {}).get("severity", "critical")
    now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")

    lines = [
        f"{title}",
        f"Status: {status}  |  Severity: {severity.upper()}",
        f"Time: {now}",
        "",
    ]

    for i, alert in enumerate(alerts):
        labels = alert.get("labels", {})
        annotations = alert.get("annotations", {})
        lines.append(f"--- Alert {i + 1} ---")
        if labels.get("alertname"):
            lines.append(f"  Alert:       {labels['alertname']}")
        if labels.get("instance"):
            lines.append(f"  Instance:    {labels['instance']}")
        if annotations.get("summary"):
            lines.append(f"  Summary:     {annotations['summary']}")
        if annotations.get("description"):
            lines.append(f"  Description: {annotations['description']}")
        if annotations.get("runbook_url"):
            lines.append(f"  Runbook:     {annotations['runbook_url']}")
        lines.append("")

    return "\n".join(lines)
