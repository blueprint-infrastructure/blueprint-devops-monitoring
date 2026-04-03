"""
Tests for lambda/teams-notifier/handler.py

Focused on the upgrade button grouping logic: VersionDrift instances with
the same (chain, current_ver, latest_ver) should share one button; different
version combinations or chains should get separate buttons.
"""

import importlib.util
import json
import os
import sys
import types
import unittest
from unittest.mock import MagicMock, patch

# ---------------------------------------------------------------------------
# Stub out AWS SDK before importing the handler
# ---------------------------------------------------------------------------

boto3_stub = types.ModuleType("boto3")
boto3_stub.client = MagicMock(return_value=MagicMock())
boto3_stub.Session = MagicMock(return_value=MagicMock())
sys.modules.setdefault("boto3", boto3_stub)

for mod in ["botocore", "botocore.auth", "botocore.awsrequest",
            "botocore.credentials", "botocore.session"]:
    sys.modules.setdefault(mod, types.ModuleType(mod))

# Load teams-notifier handler under a unique module name to avoid collision
_spec = importlib.util.spec_from_file_location(
    "teams_notifier_handler",
    os.path.join(os.path.dirname(__file__), "..", "lambda", "teams-notifier", "handler.py"),
)
notifier = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(notifier)


# ---------------------------------------------------------------------------
# Helpers to build fake alert payloads
# ---------------------------------------------------------------------------

def _make_unique_alert(instance, instance_id, chain, current_ver, latest_ver,
                       alertname="AvalancheVersionDrift"):
    """Build a unique_alerts-format dict (labels + annotations)."""
    return {
        "labels": {
            "alertname": alertname,
            "instance": instance,
            "instance_id": instance_id,
            "chain": chain,
            "version": current_ver,
            "latest_version": latest_ver,
            "severity": "warning",
        },
        "annotations": {"description": "version mismatch"},
    }


def _build_card(unique_alerts, status="firing"):
    """Call build_adaptive_card_content with correct signature."""
    alert_data = {
        "status": status,
        "alerts": unique_alerts,
        "commonLabels": {"severity": "warning", "alertname": "AvalancheVersionDrift"},
    }
    with patch.object(notifier, "_resolve_instance_id", return_value=""):
        return notifier.build_adaptive_card_content(alert_data, unique_alerts)


def _extract_upgrade_actions(card_content):
    """Return all Action.Submit actions with action_type=analyze_upgrade from a card."""
    body = card_content.get("body", [])
    actions = []
    for block in body:
        if block.get("type") == "ActionSet":
            for action in block.get("actions", []):
                data = action.get("data", {})
                if data.get("action_type") == "analyze_upgrade":
                    actions.append(action)
    return actions


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

class TestUpgradeButtonGrouping(unittest.TestCase):

    def test_single_instance_produces_one_button(self):
        alerts = [_make_unique_alert("node-1", "i-aaa", "avax", "1.14.1", "1.14.2")]
        card = _build_card(alerts)
        actions = _extract_upgrade_actions(card)
        self.assertEqual(len(actions), 1)

    def test_two_instances_same_version_produce_one_button(self):
        alerts = [
            _make_unique_alert("node-1", "i-aaa", "avax", "1.14.1", "1.14.2"),
            _make_unique_alert("node-2", "i-bbb", "avax", "1.14.1", "1.14.2"),
        ]
        card = _build_card(alerts)
        actions = _extract_upgrade_actions(card)
        self.assertEqual(len(actions), 1, "Same chain+version → one button")

    def test_both_instances_included_in_button_data(self):
        alerts = [
            _make_unique_alert("node-1", "i-aaa", "avax", "1.14.1", "1.14.2"),
            _make_unique_alert("node-2", "i-bbb", "avax", "1.14.1", "1.14.2"),
        ]
        card = _build_card(alerts)
        actions = _extract_upgrade_actions(card)
        instances = actions[0]["data"]["instances"]
        names = {i["name"] for i in instances}
        self.assertEqual(names, {"node-1", "node-2"})

    def test_different_versions_produce_separate_buttons(self):
        alerts = [
            _make_unique_alert("node-1", "i-aaa", "avax", "1.14.0", "1.14.2"),
            _make_unique_alert("node-2", "i-bbb", "avax", "1.14.1", "1.14.2"),
        ]
        card = _build_card(alerts)
        actions = _extract_upgrade_actions(card)
        self.assertEqual(len(actions), 2, "Different current_ver → two buttons")

    def test_different_chains_produce_separate_buttons(self):
        alerts = [
            _make_unique_alert("sol-1", "i-aaa", "solana", "1.18.0", "1.18.1",
                               alertname="SolanaVersionDrift"),
            _make_unique_alert("avax-1", "i-bbb", "avax", "1.14.1", "1.14.2",
                               alertname="AvalancheVersionDrift"),
        ]
        card = _build_card(alerts)
        actions = _extract_upgrade_actions(card)
        self.assertEqual(len(actions), 2, "Different chains → two buttons")

    def test_button_data_contains_version_fields(self):
        alerts = [_make_unique_alert("node-1", "i-aaa", "avax", "1.14.1", "1.14.2")]
        card = _build_card(alerts)
        actions = _extract_upgrade_actions(card)
        data = actions[0]["data"]
        self.assertEqual(data["current_ver"], "1.14.1")
        self.assertEqual(data["latest_ver"], "1.14.2")
        self.assertEqual(data["chain"], "avax")

    def test_button_title_contains_version_range(self):
        alerts = [_make_unique_alert("node-1", "i-aaa", "avax", "1.14.1", "1.14.2")]
        card = _build_card(alerts)
        actions = _extract_upgrade_actions(card)
        title = actions[0]["title"]
        self.assertIn("1.14.1", title)
        self.assertIn("1.14.2", title)

    def test_no_upgrade_button_for_non_version_drift(self):
        alerts = [
            _make_unique_alert("node-1", "i-aaa", "avax", "", "",
                               alertname="AvalancheLowPeers"),
        ]
        card = _build_card(alerts)
        actions = _extract_upgrade_actions(card)
        self.assertEqual(len(actions), 0)

    def test_rca_analyze_button_still_present_per_instance(self):
        """The 🔍 Analyze (RCA) button should still appear per-instance."""
        alerts = [
            _make_unique_alert("node-1", "i-aaa", "avax", "1.14.1", "1.14.2"),
            _make_unique_alert("node-2", "i-bbb", "avax", "1.14.1", "1.14.2"),
        ]
        card = _build_card(alerts)
        rca_actions = []
        for block in card.get("body", []):
            if block.get("type") == "ColumnSet":
                for col in block.get("columns", []):
                    for item in col.get("items", []):
                        if item.get("type") == "ActionSet":
                            for action in item.get("actions", []):
                                if action.get("data", {}).get("action_type") == "trigger_rca":
                                    rca_actions.append(action)
        self.assertEqual(len(rca_actions), 2, "RCA button per instance")

    def test_three_instances_two_groups(self):
        """Two on old version, one on newer version → two buttons."""
        alerts = [
            _make_unique_alert("node-1", "i-aaa", "avax", "1.14.0", "1.14.2"),
            _make_unique_alert("node-2", "i-bbb", "avax", "1.14.0", "1.14.2"),
            _make_unique_alert("node-3", "i-ccc", "avax", "1.14.1", "1.14.2"),
        ]
        card = _build_card(alerts)
        actions = _extract_upgrade_actions(card)
        self.assertEqual(len(actions), 2)
        # First group has 2 instances
        group_sizes = sorted(len(a["data"]["instances"]) for a in actions)
        self.assertEqual(group_sizes, [1, 2])


class TestTagComparison(unittest.TestCase):
    """Test _tag_lte imported from teams-notifier (if present)."""

    def _lte(self, a, b):
        # teams-notifier doesn't expose _tag_lte directly; test via upgrade-analyzer
        # Just validate the logic through card rendering instead.
        pass

    def test_placeholder(self):
        # _tag_lte lives in upgrade-analyzer; covered there
        pass


if __name__ == "__main__":
    unittest.main(verbosity=2)
