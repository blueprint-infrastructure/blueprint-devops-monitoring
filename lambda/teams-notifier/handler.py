"""
Lambda function: Grafana Alert -> Teams Adaptive Card + SES Email

Receives SNS notifications from Amazon Managed Grafana alerts,
formats them as Microsoft Teams Adaptive Cards, and POSTs to
a Teams webhook URL. For critical alerts (from the critical SNS topic),
also sends an HTML email via Amazon SES.

Architecture:
    AMG Alert -> SNS Topic -> This Lambda -> Teams Webhook
                                          -> SES Email (critical only)

Environment variables:
    TEAMS_WEBHOOK_URL: Microsoft Teams incoming webhook URL
    ALERT_EMAIL_SENDER: SES verified sender address
    ALERT_EMAIL_RECIPIENTS: Comma-separated recipient addresses
    STAKING_ALERT_CRITICAL_TOPIC_ARN: Critical SNS topic ARN (triggers email)
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

ses_client = boto3.client("ses")

SEVERITY_COLORS = {
    "critical": "attention",
    "high": "warning",
    "warning": "accent",
}

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


def lambda_handler(event, context):
    """Main Lambda handler - processes SNS records and posts to Teams."""
    webhook_url = os.environ.get("TEAMS_WEBHOOK_URL")
    if not webhook_url:
        logger.error("TEAMS_WEBHOOK_URL environment variable not set")
        return {"statusCode": 500, "body": "Missing TEAMS_WEBHOOK_URL"}

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

        # Always send to Teams
        card = build_adaptive_card(alert_data)
        post_to_teams(webhook_url, card)

        # Send email only for critical topic
        if topic_arn == critical_topic_arn:
            send_email(alert_data)

    return {"statusCode": 200, "body": "OK"}


# =============================================================================
# Teams Adaptive Card
# =============================================================================

def build_adaptive_card(alert_data):
    """Build a Teams Adaptive Card from Grafana alert data."""
    alerts = alert_data.get("alerts", [])

    # Plain text message (not Grafana structured)
    if not alerts and "message" in alert_data:
        return _build_simple_card(str(alert_data["message"]))

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

    # Status + severity banner
    body.append({
        "type": "TextBlock",
        "text": f"**Status:** {status.upper()}  |  **Severity:** {severity_emoji} {severity.upper()}",
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

    # Individual alert details
    for i, alert in enumerate(alerts):
        labels = alert.get("labels", {})
        annotations = alert.get("annotations", {})

        if len(alerts) > 1:
            body.append({
                "type": "TextBlock",
                "text": f"**Alert {i + 1}**",
                "wrap": True,
                "separator": True,
            })

        facts = []
        if labels.get("alertname"):
            facts.append({"title": "Alert", "value": labels["alertname"]})
        if labels.get("instance"):
            facts.append({"title": "Instance", "value": labels["instance"]})
        if annotations.get("summary"):
            facts.append({"title": "Summary", "value": annotations["summary"]})
        if annotations.get("description"):
            facts.append({"title": "Description", "value": annotations["description"]})
        if annotations.get("runbook_url"):
            facts.append({"title": "Runbook", "value": annotations["runbook_url"]})

        if facts:
            body.append({"type": "FactSet", "facts": facts})

    return _wrap_adaptive_card(body)


def _build_simple_card(message):
    """Build a simple card for non-structured messages."""
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
    return _wrap_adaptive_card(body)


def _wrap_adaptive_card(body):
    """Wrap body elements in a Power Automate Workflows Adaptive Card envelope."""
    return {
        "type": "message",
        "attachments": [
            {
                "contentType": "application/vnd.microsoft.card.adaptive",
                "contentUrl": None,
                "content": {
                    "$schema": "http://adaptivecards.io/schemas/adaptive-card.json",
                    "type": "AdaptiveCard",
                    "version": "1.4",
                    "body": body,
                },
            }
        ],
    }


def post_to_teams(webhook_url, card_payload):
    """POST the Adaptive Card to the Teams webhook."""
    data = json.dumps(card_payload).encode("utf-8")
    req = urllib.request.Request(
        webhook_url,
        data=data,
        headers={"Content-Type": "application/json"},
        method="POST",
    )

    try:
        with urllib.request.urlopen(req, timeout=10) as response:
            response_body = response.read().decode("utf-8")
            logger.info("Teams webhook response: %s %s", response.status, response_body)
    except urllib.error.HTTPError as e:
        logger.error("Teams webhook HTTP error: %s %s", e.code, e.read().decode("utf-8"))
        raise
    except urllib.error.URLError as e:
        logger.error("Teams webhook URL error: %s", e.reason)
        raise


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

    alerts = alert_data.get("alerts", [])
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
