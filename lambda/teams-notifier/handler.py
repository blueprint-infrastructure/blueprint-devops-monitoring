"""
Lambda function: Grafana Alert -> Teams (Power Automate) + SES Email + RCA Trigger

Receives SNS notifications from Amazon Managed Grafana alerts,
posts to Microsoft Teams channel via Power Automate webhook (which returns
a message_id), sends HTML email via SES for critical alerts, and triggers
the RCA Lambda for automated root cause analysis with reply-in-thread.

Architecture:
    AMG Alert -> SNS Topic -> This Lambda -> Teams webhook (returns message_id)
                                          -> SES Email (critical only)
                                          -> RCA Lambda (async, reply-in-thread)

Environment variables:
    TEAMS_WEBHOOK_URL: Power Automate webhook URL for posting alerts
    ALERT_EMAIL_SENDER: SES verified sender address
    ALERT_EMAIL_RECIPIENTS: Comma-separated recipient addresses
    STAKING_ALERT_CRITICAL_TOPIC_ARN: Critical SNS topic ARN (triggers email)
    RCA_LAMBDA_FUNCTION_NAME: Name of the RCA analyzer Lambda function
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
lambda_client = boto3.client("lambda")

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
    webhook_url = os.environ.get("TEAMS_WEBHOOK_URL", "")
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

        # Deduplicate alerts by instance
        unique_alerts = _deduplicate_alerts(alert_data.get("alerts", []))

        # Send to Teams via webhook, capture message_id from response
        message_id = None
        card = build_adaptive_card(alert_data, unique_alerts)
        try:
            message_id = post_to_teams(webhook_url, card)
        except Exception:
            logger.exception("Teams webhook failed")

        # Send email only for critical topic
        if topic_arn == critical_topic_arn:
            send_email(alert_data)

        # Trigger RCA for firing alerts
        status = alert_data.get("status", "").lower()
        if status == "firing":
            trigger_rca(alert_data, unique_alerts, message_id)

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
# Teams Webhook (Power Automate)
# =============================================================================

def post_to_teams(webhook_url, card_payload):
    """POST the Adaptive Card to the Teams webhook.

    The Power Automate flow should be configured to return a JSON response
    containing the message_id of the posted message. If the response contains
    a message_id, it is returned for use in reply-in-thread.
    """
    data = json.dumps(card_payload).encode("utf-8")
    req = urllib.request.Request(
        webhook_url,
        data=data,
        headers={"Content-Type": "application/json"},
        method="POST",
    )

    try:
        with urllib.request.urlopen(req, timeout=15) as response:
            response_body = response.read().decode("utf-8")
            logger.info("Teams webhook response: %s %s", response.status, response_body[:200])

            # Try to parse message_id from response
            # Power Automate flow should return: {"message_id": "..."}
            try:
                resp_data = json.loads(response_body)
                message_id = resp_data.get("message_id")
                if message_id:
                    logger.info("Got message_id from webhook: %s", message_id)
                    return message_id
            except (json.JSONDecodeError, AttributeError):
                pass

            return None
    except urllib.error.HTTPError as e:
        logger.error("Teams webhook HTTP error: %s %s", e.code, e.read().decode("utf-8"))
        raise
    except urllib.error.URLError as e:
        logger.error("Teams webhook URL error: %s", e.reason)
        raise


def build_adaptive_card(alert_data, unique_alerts):
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

    # Common description + runbook (show once, from first alert)
    if unique_alerts:
        first_ann = unique_alerts[0].get("annotations", {})
        desc = first_ann.get("description", "")
        runbook = first_ann.get("runbook_url", "")

        if desc:
            body.append({
                "type": "TextBlock",
                "text": f"**Description:** {desc}",
                "wrap": True,
                "separator": True,
            })
        if runbook:
            body.append({
                "type": "TextBlock",
                "text": f"**Runbook:** [{runbook}]({runbook})",
                "wrap": True,
            })

    # Compact instance list
    instance_lines = []
    for alert in unique_alerts:
        labels = alert.get("labels", {})
        instance = labels.get("instance", "unknown")
        chain = labels.get("chain", "")
        prefix = f"[{chain}] " if chain else ""
        instance_lines.append(f"- {prefix}**{instance}**")

    if instance_lines:
        body.append({
            "type": "TextBlock",
            "text": "**Affected instances:**",
            "wrap": True,
            "separator": True,
            "weight": "Bolder",
        })
        body.append({
            "type": "TextBlock",
            "text": "\n".join(instance_lines),
            "wrap": True,
        })

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


# =============================================================================
# RCA Trigger
# =============================================================================

def trigger_rca(alert_data, unique_alerts, parent_message_id):
    """Trigger RCA Lambda asynchronously for each alert with instance_id."""
    rca_function = os.environ.get("RCA_LAMBDA_FUNCTION_NAME", "")
    if not rca_function:
        logger.info("RCA_LAMBDA_FUNCTION_NAME not set, skipping RCA trigger")
        return

    for alert in unique_alerts:
        labels = alert.get("labels", {})
        annotations = alert.get("annotations", {})
        instance_id = labels.get("instance_id", "")

        if not instance_id:
            logger.info("No instance_id for %s, skipping RCA", labels.get("instance", ""))
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
