"""
Lambda function: Bot Framework messaging endpoint for Teams button clicks.

Receives invoke activities from Teams when users click Action.Submit buttons
on alert Adaptive Cards. Triggers the RCA analyzer Lambda asynchronously
and returns an immediate acknowledgment to Teams.

Architecture:
    User clicks button -> Teams -> API Gateway -> This Lambda
        -> Invoke RCA Lambda (async)
        -> Return "RCA triggered" card to Teams

Environment variables:
    TEAMS_BOT_SECRET_ARN: Secrets Manager ARN for Bot credentials
    RCA_LAMBDA_FUNCTION_NAME: Name of the RCA analyzer Lambda
"""

import json
import logging
import os
import urllib.error
import urllib.parse
import urllib.request

import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

lambda_client = boto3.client("lambda")
secrets_client = boto3.client("secretsmanager")

UPGRADE_LAMBDA_FUNCTION_NAME = os.environ.get(
    "UPGRADE_LAMBDA_FUNCTION_NAME", "staking-alert-upgrade-analyzer"
)

_bot_config = None


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


def lambda_handler(event, context):
    """Handle incoming Bot Framework activities from API Gateway."""
    # Parse API Gateway event
    body = event.get("body", "{}")
    if event.get("isBase64Encoded"):
        import base64
        body = base64.b64decode(body).decode("utf-8")

    try:
        activity = json.loads(body)
    except json.JSONDecodeError:
        logger.error("Invalid JSON body: %s", body[:200])
        return {"statusCode": 400, "body": "Invalid JSON"}

    activity_type = activity.get("type", "")
    logger.info("Received activity: type=%s, keys=%s", activity_type, list(activity.keys()))
    logger.info("Activity body (first 1000): %s", json.dumps(activity)[:1000])

    # Handle invoke activities (Action.Execute button clicks)
    if activity_type == "invoke":
        return handle_invoke(activity)

    # Handle message activities - Action.Submit sends as message type with value field
    if activity_type == "message":
        value = activity.get("value", {})
        if isinstance(value, dict):
            action_type = value.get("action_type", "")
            if action_type == "trigger_rca":
                logger.info("Action.Submit detected in message activity")
                return trigger_rca_from_button(activity, value)
            elif action_type == "upgrade_plan":
                logger.info("Upgrade plan Action.Submit detected in message activity")
                return trigger_upgrade_plan_from_button(activity, value)
        return {"statusCode": 200, "body": ""}

    # Default: acknowledge
    return {"statusCode": 200, "body": ""}


def handle_invoke(activity):
    """Handle an invoke activity (Action.Submit from Adaptive Card)."""
    value = activity.get("value", {})
    action = value.get("action", {})
    data = action.get("data", value)  # Action.Execute uses value.action.data, Action.Submit uses value directly

    logger.info("Invoke data: %s", json.dumps(data)[:500])

    action_type = data.get("action_type", "")

    if action_type == "trigger_rca":
        return trigger_rca_from_button(activity, data)

    elif action_type == "upgrade_plan":
        return trigger_upgrade_plan_from_button(activity, data)

    logger.warning("Unknown action_type: %s", action_type)
    return _invoke_response(200, "Unknown action")


def trigger_rca_from_button(activity, data):
    """Trigger RCA for a specific instance from a button click."""
    rca_function = os.environ.get("RCA_LAMBDA_FUNCTION_NAME", "")
    if not rca_function:
        return _invoke_response(200, "RCA not configured")

    # Extract conversation info for reply-in-thread
    conversation = activity.get("conversation", {})
    # The parent message ID is in the replyToId of the invoke activity
    reply_to_id = activity.get("replyToId", "")
    if not reply_to_id:
        # Fallback: try to get from the conversation id (;messageid=xxx)
        conv_id = conversation.get("id", "")
        if ";messageid=" in conv_id:
            reply_to_id = conv_id.split(";messageid=")[-1]

    instance_name = data.get("instance", "")
    instance_id = data.get("instance_id", "")

    logger.info("RCA button clicked: instance=%s(%s), parent_msg=%s",
                instance_name, instance_id, reply_to_id)

    # Build RCA payload
    rca_payload = {
        "alertname": data.get("alertname", ""),
        "instance": instance_name,
        "instance_id": instance_id,
        "chain": data.get("chain", ""),
        "severity": data.get("severity", ""),
        "status": "firing",
        "description": data.get("description", ""),
        "summary": data.get("summary", ""),
        "runbook_url": data.get("runbook_url", ""),
        "labels": data.get("labels", {}),
        "parent_message_id": reply_to_id,
    }

    try:
        lambda_client.invoke(
            FunctionName=rca_function,
            InvocationType="Event",  # async
            Payload=json.dumps(rca_payload).encode("utf-8"),
        )
        logger.info("RCA triggered for %s (%s)", instance_name, instance_id)

        # Return updated card or message to acknowledge
        return _invoke_response(
            200,
            f"\U0001f504 Analyzing **{instance_name}**... Results will appear in this thread shortly."
        )
    except Exception:
        logger.exception("Failed to trigger RCA")
        return _invoke_response(200, "\u274c Failed to trigger RCA analysis")


def trigger_upgrade_plan_from_button(activity, data):
    """Trigger upgrade plan analysis for a specific instance from a button click."""
    # Extract conversation info for reply-in-thread
    conversation = activity.get("conversation", {})
    reply_to_id = activity.get("replyToId", "")
    if not reply_to_id:
        conv_id = conversation.get("id", "")
        if ";messageid=" in conv_id:
            reply_to_id = conv_id.split(";messageid=")[-1]

    instance_name = data.get("instance", "")
    instance_id = data.get("instance_id", "")

    logger.info("Upgrade plan button clicked: instance=%s(%s), parent_msg=%s",
                instance_name, instance_id, reply_to_id)

    payload = {
        "alertname":         data.get("alertname", ""),
        "instance":          instance_name,
        "instance_id":       instance_id,
        "chain":             data.get("chain", ""),
        "labels":            data.get("labels", {}),
        "parent_message_id": reply_to_id,
        "service_url":       activity.get("serviceUrl", ""),
        "channel_id":        conversation.get("id", "").split(";")[0],
    }

    try:
        lambda_client.invoke(
            FunctionName=UPGRADE_LAMBDA_FUNCTION_NAME,
            InvocationType="Event",  # async
            Payload=json.dumps(payload).encode("utf-8"),
        )
        logger.info("Upgrade analyzer triggered for %s (%s)", instance_name, instance_id)

        return _invoke_response(
            200,
            f"\U0001f4cb Generating upgrade plan for **{instance_name}**... "
            "Results will appear in this thread shortly."
        )
    except Exception:
        logger.exception("Failed to trigger upgrade analyzer")
        return _invoke_response(200, "\u274c Failed to trigger upgrade plan analysis")


def _invoke_response(status_code, message):
    """Build an invoke response that sends a message back to Teams."""
    # For adaptiveCard/action invoke, return a card or message
    response_body = {
        "statusCode": 200,
        "type": "application/vnd.microsoft.activity.message",
        "value": message,
    }
    return {
        "statusCode": status_code,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(response_body),
    }
