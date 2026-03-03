"""
Lambda function: Grafana Alert -> Teams Adaptive Card

Receives SNS notifications from Amazon Managed Grafana alerts,
formats them as Microsoft Teams Adaptive Cards, and POSTs to
a Teams webhook URL (Power Automate Workflows).

Architecture:
    AMG Alert -> SNS Topic -> This Lambda -> Teams Webhook

Environment variables:
    TEAMS_WEBHOOK_URL: Microsoft Teams incoming webhook URL
"""

import json
import logging
import os
import urllib.error
import urllib.request
from datetime import datetime, timezone

logger = logging.getLogger()
logger.setLevel(logging.INFO)

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


def lambda_handler(event, context):
    """Main Lambda handler - processes SNS records and posts to Teams."""
    webhook_url = os.environ.get("TEAMS_WEBHOOK_URL")
    if not webhook_url:
        logger.error("TEAMS_WEBHOOK_URL environment variable not set")
        return {"statusCode": 500, "body": "Missing TEAMS_WEBHOOK_URL"}

    for record in event.get("Records", []):
        sns_message = record.get("Sns", {}).get("Message", "{}")
        logger.info("Received SNS message: %s", sns_message[:500])

        try:
            alert_data = json.loads(sns_message)
        except json.JSONDecodeError:
            alert_data = {"message": sns_message}

        card = build_adaptive_card(alert_data)
        post_to_teams(webhook_url, card)

    return {"statusCode": 200, "body": "OK"}


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
