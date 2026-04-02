"""
Tests for lambda/bot-endpoint/handler.py

Covers:
- trigger_upgrade_plan_from_button: new multi-instance format
- trigger_upgrade_plan_from_button: backward-compat with old single-instance format
- trigger_post_upgrade_from_button: correct payload forwarded to upgrade-analyzer
- handle_invoke / message handler: correct action_type routing
"""

import importlib.util
import json
import os
import sys
import types
import unittest
from unittest.mock import MagicMock, patch

# ---------------------------------------------------------------------------
# Stub AWS SDK
# ---------------------------------------------------------------------------

_lambda_mock = MagicMock()
_secrets_mock = MagicMock()

boto3_stub = types.ModuleType("boto3")

def _boto3_client(svc, **kw):
    return {"lambda": _lambda_mock, "secretsmanager": _secrets_mock}.get(svc, MagicMock())

boto3_stub.client = MagicMock(side_effect=_boto3_client)
boto3_stub.Session = MagicMock(return_value=MagicMock())
sys.modules["boto3"] = boto3_stub

for mod in ["botocore", "botocore.auth", "botocore.awsrequest",
            "botocore.credentials", "botocore.session"]:
    sys.modules.setdefault(mod, types.ModuleType(mod))

# Load bot-endpoint handler under a unique module name
_spec = importlib.util.spec_from_file_location(
    "bot_endpoint_handler",
    os.path.join(os.path.dirname(__file__), "..", "lambda", "bot-endpoint", "handler.py"),
)
bot = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(bot)

UPGRADE_FN = "staking-alert-upgrade-analyzer"


def _make_activity(value, activity_type="message", service_url="https://smba.net/",
                   conv_id="19:abc@thread.tacv2", reply_to_id="msg-123"):
    return {
        "type": activity_type,
        "value": value,
        "replyToId": reply_to_id,
        "serviceUrl": service_url,
        "conversation": {"id": conv_id},
    }


def _captured_payload():
    """Return the JSON payload that was sent to lambda_client.invoke."""
    call_kwargs = _lambda_mock.invoke.call_args[1]
    return json.loads(call_kwargs["Payload"])


class TestTriggerUpgradePlanNewFormat(unittest.TestCase):
    """New button data format: instances list + current_ver/latest_ver."""

    def setUp(self):
        _lambda_mock.reset_mock()

    def test_invokes_upgrade_lambda(self):
        data = {
            "action_type": "analyze_upgrade",
            "chain": "avax",
            "current_ver": "1.14.1",
            "latest_ver": "1.14.2",
            "instances": [
                {"name": "node-1", "id": "i-aaa"},
                {"name": "node-2", "id": "i-bbb"},
            ],
            "alertname": "AvalancheVersionDrift",
            "labels": {},
        }
        bot.trigger_upgrade_plan_from_button(_make_activity(data), data)
        _lambda_mock.invoke.assert_called_once()
        kwargs = _lambda_mock.invoke.call_args[1]
        self.assertEqual(kwargs["FunctionName"], UPGRADE_FN)
        self.assertEqual(kwargs["InvocationType"], "Event")

    def test_payload_contains_instances_list(self):
        data = {
            "action_type": "analyze_upgrade",
            "chain": "avax",
            "current_ver": "1.14.1",
            "latest_ver": "1.14.2",
            "instances": [
                {"name": "node-1", "id": "i-aaa"},
                {"name": "node-2", "id": "i-bbb"},
            ],
            "labels": {},
        }
        bot.trigger_upgrade_plan_from_button(_make_activity(data), data)
        payload = _captured_payload()
        self.assertEqual(len(payload["instances"]), 2)
        self.assertEqual(payload["current_ver"], "1.14.1")
        self.assertEqual(payload["latest_ver"], "1.14.2")
        self.assertEqual(payload["chain"], "avax")

    def test_payload_includes_parent_message_id(self):
        data = {"action_type": "analyze_upgrade", "chain": "avax",
                "current_ver": "1.14.1", "latest_ver": "1.14.2",
                "instances": [{"name": "n1", "id": "i-1"}], "labels": {}}
        bot.trigger_upgrade_plan_from_button(_make_activity(data, reply_to_id="reply-999"), data)
        payload = _captured_payload()
        self.assertEqual(payload["parent_message_id"], "reply-999")

    def test_payload_includes_service_url_and_channel_id(self):
        data = {"action_type": "analyze_upgrade", "chain": "sol",
                "current_ver": "1.18.0", "latest_ver": "1.18.1",
                "instances": [{"name": "sol-1", "id": "i-sol"}], "labels": {}}
        activity = _make_activity(data, service_url="https://custom.teams/",
                                  conv_id="19:channel@thread.tacv2;messageid=xxx")
        bot.trigger_upgrade_plan_from_button(activity, data)
        payload = _captured_payload()
        self.assertEqual(payload["service_url"], "https://custom.teams/")
        self.assertEqual(payload["channel_id"], "19:channel@thread.tacv2")

    def test_action_type_in_payload_is_upgrade_plan(self):
        data = {"action_type": "analyze_upgrade", "chain": "avax",
                "current_ver": "1.14.1", "latest_ver": "1.14.2",
                "instances": [{"name": "n1", "id": "i-1"}], "labels": {}}
        bot.trigger_upgrade_plan_from_button(_make_activity(data), data)
        payload = _captured_payload()
        self.assertEqual(payload["action_type"], "upgrade_plan")


class TestTriggerUpgradePlanOldFormat(unittest.TestCase):
    """Backward-compat: old single-instance format (validator_name, client_version)."""

    def setUp(self):
        _lambda_mock.reset_mock()

    def test_old_format_creates_single_instance_list(self):
        data = {
            "action_type": "upgrade_plan",
            "chain": "avax",
            "validator_name": "node-old",
            "instance_id": "i-old",
            "client_version": "1.13.0",
            "latest_version": "1.14.0",
            "labels": {},
        }
        bot.trigger_upgrade_plan_from_button(_make_activity(data), data)
        payload = _captured_payload()
        self.assertEqual(len(payload["instances"]), 1)
        self.assertEqual(payload["instances"][0]["name"], "node-old")
        self.assertEqual(payload["instances"][0]["id"], "i-old")

    def test_old_format_version_fields_preserved(self):
        data = {
            "action_type": "upgrade_plan",
            "chain": "avax",
            "validator_name": "node-old",
            "instance_id": "i-old",
            "client_version": "1.13.0",
            "latest_version": "1.14.0",
            "labels": {},
        }
        bot.trigger_upgrade_plan_from_button(_make_activity(data), data)
        payload = _captured_payload()
        self.assertEqual(payload["current_ver"], "1.13.0")
        self.assertEqual(payload["latest_ver"], "1.14.0")

    def test_old_format_instance_field_fallback(self):
        data = {
            "action_type": "upgrade_plan",
            "chain": "avax",
            "instance": "node-via-instance",
            "instance_id": "i-xyz",
            "labels": {},
        }
        bot.trigger_upgrade_plan_from_button(_make_activity(data), data)
        payload = _captured_payload()
        self.assertEqual(payload["instances"][0]["name"], "node-via-instance")


class TestTriggerPostUpgrade(unittest.TestCase):

    def setUp(self):
        _lambda_mock.reset_mock()

    def test_invokes_upgrade_lambda(self):
        data = {
            "action_type": "run_post_upgrade",
            "notion_page_id": "page-abc",
            "instances": [{"name": "node-1", "id": "i-aaa"}],
            "post_upgrade_commands": ["systemctl status avalanchego"],
            "chain": "avax",
            "current_ver": "1.14.1",
            "latest_ver": "1.14.2",
        }
        bot.trigger_post_upgrade_from_button(_make_activity(data), data)
        _lambda_mock.invoke.assert_called_once()
        kwargs = _lambda_mock.invoke.call_args[1]
        self.assertEqual(kwargs["FunctionName"], UPGRADE_FN)
        self.assertEqual(kwargs["InvocationType"], "Event")

    def test_payload_action_type_is_run_post_upgrade(self):
        data = {
            "action_type": "run_post_upgrade",
            "notion_page_id": "page-abc",
            "instances": [{"name": "node-1", "id": "i-aaa"}],
            "post_upgrade_commands": ["avalanchego --version"],
            "chain": "avax",
            "current_ver": "1.14.1",
            "latest_ver": "1.14.2",
        }
        bot.trigger_post_upgrade_from_button(_make_activity(data), data)
        payload = _captured_payload()
        self.assertEqual(payload["action_type"], "run_post_upgrade")
        self.assertEqual(payload["notion_page_id"], "page-abc")
        self.assertIn("avalanchego --version", payload["post_upgrade_commands"])

    def test_parent_message_id_passed_through(self):
        data = {
            "action_type": "run_post_upgrade",
            "notion_page_id": "page-abc",
            "instances": [],
            "post_upgrade_commands": [],
            "chain": "avax",
        }
        bot.trigger_post_upgrade_from_button(_make_activity(data, reply_to_id="msg-777"), data)
        payload = _captured_payload()
        self.assertEqual(payload["parent_message_id"], "msg-777")

    def test_service_url_and_channel_id_passed_through(self):
        data = {
            "action_type": "run_post_upgrade",
            "notion_page_id": "p",
            "instances": [],
            "post_upgrade_commands": [],
            "chain": "avax",
        }
        activity = _make_activity(data, service_url="https://my.teams/",
                                  conv_id="19:ch@thread;messageid=888")
        bot.trigger_post_upgrade_from_button(activity, data)
        payload = _captured_payload()
        self.assertEqual(payload["service_url"], "https://my.teams/")
        self.assertEqual(payload["channel_id"], "19:ch@thread")


class TestRouting(unittest.TestCase):
    """handle_invoke and message-type routing dispatches to correct handler."""

    def setUp(self):
        _lambda_mock.reset_mock()

    def _invoke_activity(self, action_type):
        data = {"action_type": action_type, "chain": "avax",
                "current_ver": "1.14.1", "latest_ver": "1.14.2",
                "instances": [], "labels": {}}
        activity = {
            "type": "invoke",
            "value": {"action": {"data": data}},
            "replyToId": "msg-1",
            "serviceUrl": "https://smba.net/",
            "conversation": {"id": "19:ch@thread"},
        }
        return bot.handle_invoke(activity)

    def test_trigger_rca_routing(self):
        with patch.object(bot, "trigger_rca_from_button") as mock_rca:
            mock_rca.return_value = {"statusCode": 200, "body": ""}
            self._invoke_activity("trigger_rca")
            mock_rca.assert_called_once()

    def test_analyze_upgrade_routing(self):
        with patch.object(bot, "trigger_upgrade_plan_from_button") as mock_up:
            mock_up.return_value = {"statusCode": 200, "body": ""}
            self._invoke_activity("analyze_upgrade")
            mock_up.assert_called_once()

    def test_upgrade_plan_routing(self):
        with patch.object(bot, "trigger_upgrade_plan_from_button") as mock_up:
            mock_up.return_value = {"statusCode": 200, "body": ""}
            self._invoke_activity("upgrade_plan")
            mock_up.assert_called_once()

    def test_run_post_upgrade_routing(self):
        with patch.object(bot, "trigger_post_upgrade_from_button") as mock_post:
            mock_post.return_value = {"statusCode": 200, "body": ""}
            self._invoke_activity("run_post_upgrade")
            mock_post.assert_called_once()

    def test_unknown_action_returns_200(self):
        result = self._invoke_activity("unknown_action")
        self.assertEqual(result["statusCode"], 200)


if __name__ == "__main__":
    unittest.main(verbosity=2)
