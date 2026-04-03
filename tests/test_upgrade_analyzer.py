"""
Tests for lambda/upgrade-analyzer/handler.py

Covers:
- lambda_handler dispatch (upgrade_plan vs run_post_upgrade)
- _get_versions: priority order (event hints > labels > AMP fallback)
- _tag_lte: semver comparison
- _build_notion_blocks: structure and content
- _build_summary_card: Notion link + verify button
- _build_verification_card: results summary
- _run_pre_upgrade_on_instances: SSM delegation + error handling
- Notion search/create/update helpers (mocked HTTP)
"""

import importlib.util
import json
import os
import sys
import types
import unittest
from unittest.mock import MagicMock, patch

# ---------------------------------------------------------------------------
# Stub AWS SDK + botocore before importing handler
# ---------------------------------------------------------------------------

_secrets_mock = MagicMock()
_ssm_mock = MagicMock()

boto3_stub = types.ModuleType("boto3")

def _boto3_client(svc, **kw):
    return {"secretsmanager": _secrets_mock, "ssm": _ssm_mock}.get(svc, MagicMock())

boto3_stub.client = MagicMock(side_effect=_boto3_client)
boto3_stub.Session = MagicMock(return_value=MagicMock(
    get_credentials=MagicMock(return_value=MagicMock(
        get_frozen_credentials=MagicMock(return_value=MagicMock())
    ))
))
sys.modules["boto3"] = boto3_stub

# Botocore stubs
bc = types.ModuleType("botocore")
bc_auth = types.ModuleType("botocore.auth")
bc_auth.SigV4Auth = MagicMock()
bc_req = types.ModuleType("botocore.awsrequest")

class _FakeAWSRequest:
    def __init__(self, **kw):
        self.headers = {}
    def prepare(self):
        m = MagicMock()
        m.url = "https://fake-aps/query"
        m.headers = {}
        return m

bc_req.AWSRequest = _FakeAWSRequest
bc_cred = types.ModuleType("botocore.credentials")
bc_sess = types.ModuleType("botocore.session")
for name, mod in [("botocore", bc), ("botocore.auth", bc_auth),
                  ("botocore.awsrequest", bc_req), ("botocore.credentials", bc_cred),
                  ("botocore.session", bc_sess)]:
    sys.modules[name] = mod

# Load upgrade-analyzer handler under a unique module name to avoid collision
_spec = importlib.util.spec_from_file_location(
    "upgrade_analyzer_handler",
    os.path.join(os.path.dirname(__file__), "..", "lambda", "upgrade-analyzer", "handler.py"),
)
analyzer = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(analyzer)

# ---------------------------------------------------------------------------
# Sample data
# ---------------------------------------------------------------------------

SAMPLE_PLAN = {
    "summary": "Upgrade avalanchego from 1.14.1 to 1.14.2",
    "breaking_changes": ["Requires config field X"],
    "pre_upgrade_steps": [
        {"step": "1", "description": "Backup config", "command": "cp ~/.avalanchego ~/.avalanchego.bak"},
        {"step": "2", "description": "Check disk space", "command": "df -h /"},
    ],
    "upgrade_steps": [
        {"step": "1", "description": "Download new binary", "command": "wget https://example.com/avalanchego-1.14.2"},
    ],
    "post_upgrade_steps": [
        {"step": "1", "description": "Verify version", "command": "avalanchego --version"},
    ],
    "rollback_steps": ["Restore binary", "Restart service"],
    "estimated_downtime": "~5 min",
    "notes": "Hot upgrade supported",
}

INSTANCES = [
    {"name": "node-1", "id": "i-aaa"},
    {"name": "node-2", "id": "i-bbb"},
]


# ---------------------------------------------------------------------------
# Tests: lambda_handler dispatch
# ---------------------------------------------------------------------------

class TestDispatch(unittest.TestCase):

    def test_default_dispatches_to_upgrade_plan(self):
        with patch.object(analyzer, "_handle_upgrade_plan") as mock_up:
            mock_up.return_value = {"status": "ok"}
            analyzer.lambda_handler({"action_type": "upgrade_plan", "chain": "avax"}, None)
            mock_up.assert_called_once()

    def test_missing_action_type_defaults_to_upgrade_plan(self):
        with patch.object(analyzer, "_handle_upgrade_plan") as mock_up:
            mock_up.return_value = {"status": "ok"}
            analyzer.lambda_handler({"chain": "avax"}, None)
            mock_up.assert_called_once()

    def test_run_post_upgrade_dispatches_correctly(self):
        with patch.object(analyzer, "_handle_post_upgrade_verification") as mock_post:
            mock_post.return_value = {"status": "ok"}
            analyzer.lambda_handler({"action_type": "run_post_upgrade"}, None)
            mock_post.assert_called_once()


# ---------------------------------------------------------------------------
# Tests: _get_versions priority
# ---------------------------------------------------------------------------

class TestGetVersions(unittest.TestCase):

    def test_event_hints_take_priority(self):
        current, latest = analyzer._get_versions(
            chain="avax", instance="node-1",
            labels={"version": "label-ver", "latest_version": "label-latest"},
            current_ver_hint="1.14.1", latest_ver_hint="1.14.2",
        )
        self.assertEqual(current, "1.14.1")
        self.assertEqual(latest, "1.14.2")

    def test_labels_used_when_no_hints(self):
        current, latest = analyzer._get_versions(
            chain="avax", instance="node-1",
            labels={"version": "1.13.0", "latest_version": "1.14.0"},
        )
        self.assertEqual(current, "1.13.0")
        self.assertEqual(latest, "1.14.0")

    def test_only_one_hint_falls_back_to_labels(self):
        # current_ver_hint provided but no latest_ver_hint → falls through to labels
        current, latest = analyzer._get_versions(
            chain="avax", instance="node-1",
            labels={"version": "1.13.0", "latest_version": "1.14.0"},
            current_ver_hint="1.14.1", latest_ver_hint="",
        )
        # Both hints must be present to short-circuit; falls to label path
        self.assertEqual(current, "1.13.0")
        self.assertEqual(latest, "1.14.0")

    def test_returns_unknown_when_nothing_found(self):
        current, latest = analyzer._get_versions(
            chain="canton", instance="node-1",
            labels={},
        )
        self.assertEqual(current, "unknown")
        self.assertEqual(latest, "unknown")

    def test_partial_labels_returns_unknown_for_missing(self):
        # current_ver in labels but no latest_version
        current, latest = analyzer._get_versions(
            chain="canton", instance="node-1",
            labels={"version": "1.0.0"},
        )
        # Falls through AMP (no workspace) and github (canton has no repos)
        self.assertEqual(current, "1.0.0")
        self.assertEqual(latest, "unknown")


# ---------------------------------------------------------------------------
# Tests: _tag_lte semver comparison
# ---------------------------------------------------------------------------

class TestTagLte(unittest.TestCase):

    def test_older_is_lte(self):
        self.assertTrue(analyzer._tag_lte("v1.14.0", "v1.14.1"))

    def test_equal_is_lte(self):
        self.assertTrue(analyzer._tag_lte("v1.14.1", "v1.14.1"))

    def test_newer_is_not_lte(self):
        self.assertFalse(analyzer._tag_lte("v1.14.2", "v1.14.1"))

    def test_handles_no_v_prefix(self):
        self.assertTrue(analyzer._tag_lte("1.14.0", "1.14.1"))

    def test_major_version_difference(self):
        self.assertTrue(analyzer._tag_lte("v1.13.9", "v2.0.0"))
        self.assertFalse(analyzer._tag_lte("v2.0.0", "v1.14.0"))

    def test_patch_difference(self):
        self.assertFalse(analyzer._tag_lte("v1.14.3", "v1.14.2"))
        self.assertTrue(analyzer._tag_lte("v1.14.1", "v1.14.3"))


# ---------------------------------------------------------------------------
# Tests: _build_notion_blocks
# ---------------------------------------------------------------------------

class TestBuildNotionBlocks(unittest.TestCase):

    def _build(self, plan=None, pre_results=None, instances=None):
        return analyzer._build_notion_blocks(
            plan=plan or SAMPLE_PLAN,
            pre_results=pre_results or [],
            instances=instances or INSTANCES,
            chain="avax",
            current_ver="1.14.1",
            latest_ver="1.14.2",
        )

    def test_returns_list(self):
        blocks = self._build()
        self.assertIsInstance(blocks, list)
        self.assertGreater(len(blocks), 0)

    def test_pre_upgrade_commands_appear_as_code_blocks(self):
        blocks = self._build()
        code_blocks = [b for b in blocks if b["type"] == "code"]
        commands = [b["code"]["rich_text"][0]["text"]["content"] for b in code_blocks]
        self.assertTrue(any("cp ~/.avalanchego" in c for c in commands))
        self.assertTrue(any("df -h" in c for c in commands))

    def test_upgrade_steps_not_auto_run_notice_present(self):
        blocks = self._build()
        callout_texts = [
            b["callout"]["rich_text"][0]["text"]["content"]
            for b in blocks if b["type"] == "callout"
        ]
        self.assertTrue(
            any("manual" in t.lower() or "Manual" in t for t in callout_texts),
            f"No 'manual' callout found in: {callout_texts}",
        )

    def test_post_upgrade_steps_marked_pending(self):
        blocks = self._build()
        callout_texts = [
            b["callout"]["rich_text"][0]["text"]["content"]
            for b in blocks if b["type"] == "callout"
        ]
        # Callout should indicate post-upgrade steps are not yet executed
        self.assertTrue(
            any("Post-Upgrade" in t or "triggered" in t or "after" in t for t in callout_texts),
            f"No post-upgrade pending callout found in: {callout_texts}",
        )

    def test_ssm_results_included_when_present(self):
        pre_results = [
            {"instance_name": "node-1", "output": "OK: config backed up"},
            {"instance_name": "node-2", "output": "OK: disk 50% used"},
        ]
        blocks = self._build(pre_results=pre_results)
        all_text = json.dumps(blocks)
        self.assertIn("node-1", all_text)
        self.assertIn("OK: config backed up", all_text)

    def test_breaking_changes_listed(self):
        blocks = self._build()
        bullet_texts = [
            b["bulleted_list_item"]["rich_text"][0]["text"]["content"]
            for b in blocks if b["type"] == "bulleted_list_item"
        ]
        self.assertTrue(any("config field X" in t for t in bullet_texts))

    def test_no_pre_upgrade_section_when_no_steps(self):
        plan_no_pre = dict(SAMPLE_PLAN, pre_upgrade_steps=[])
        blocks = self._build(plan=plan_no_pre)
        heading_texts = []
        for b in blocks:
            for htype in ("heading_2", "heading_3"):
                if b["type"] == htype:
                    heading_texts.append(b[htype]["rich_text"][0]["text"]["content"])
        self.assertFalse(any("Pre-Upgrade" in h for h in heading_texts))

    def test_header_callout_contains_chain_and_version(self):
        blocks = self._build()
        callout_texts = [
            b["callout"]["rich_text"][0]["text"]["content"]
            for b in blocks if b["type"] == "callout"
        ]
        header = callout_texts[0]
        self.assertIn("avax", header.lower())
        self.assertIn("1.14.1", header)
        self.assertIn("1.14.2", header)


# ---------------------------------------------------------------------------
# Tests: _build_summary_card
# ---------------------------------------------------------------------------

class TestBuildSummaryCard(unittest.TestCase):

    def _build(self, page_url="https://notion.so/page", page_id="page-1",
               post_cmds=None, pre_results=None):
        if post_cmds is None:
            post_cmds = ["avalanchego --version"]
        return analyzer._build_summary_card(
            chain="avax",
            current_ver="1.14.1",
            latest_ver="1.14.2",
            instances=INSTANCES,
            page_url=page_url,
            page_id=page_id,
            post_upgrade_commands=post_cmds,
            parent_msg="msg-123",
            service_url="https://smba.net/",
            channel_id="19:ch@thread",
            pre_results=pre_results or [],
        )

    def test_returns_adaptive_card(self):
        card = self._build()
        self.assertEqual(card["type"], "AdaptiveCard")

    def test_notion_link_action_present(self):
        card = self._build()
        all_actions = [
            a for block in card["body"] if block.get("type") == "ActionSet"
            for a in block.get("actions", [])
        ]
        open_url_actions = [a for a in all_actions if a["type"] == "Action.OpenUrl"]
        self.assertEqual(len(open_url_actions), 1)
        self.assertEqual(open_url_actions[0]["url"], "https://notion.so/page")

    def test_verify_button_present_when_post_cmds_exist(self):
        card = self._build(post_cmds=["avalanchego --version"])
        all_actions = [
            a for block in card["body"] if block.get("type") == "ActionSet"
            for a in block.get("actions", [])
        ]
        verify_actions = [a for a in all_actions
                          if a.get("data", {}).get("action_type") == "run_post_upgrade"]
        self.assertEqual(len(verify_actions), 1)

    def test_verify_button_data_contains_instances_and_commands(self):
        card = self._build(post_cmds=["avalanchego --version"])
        all_actions = [
            a for block in card["body"] if block.get("type") == "ActionSet"
            for a in block.get("actions", [])
        ]
        verify_action = next(
            a for a in all_actions
            if a.get("data", {}).get("action_type") == "run_post_upgrade"
        )
        data = verify_action["data"]
        self.assertEqual(len(data["instances"]), 2)
        self.assertIn("avalanchego --version", data["post_upgrade_commands"])
        self.assertEqual(data["notion_page_id"], "page-1")
        self.assertEqual(data["parent_message_id"], "msg-123")

    def test_no_verify_button_when_no_post_cmds(self):
        card = self._build(post_cmds=[])
        all_actions = [
            a for block in card["body"] if block.get("type") == "ActionSet"
            for a in block.get("actions", [])
        ]
        verify_actions = [a for a in all_actions
                          if a.get("data", {}).get("action_type") == "run_post_upgrade"]
        self.assertEqual(len(verify_actions), 0)

    def test_no_notion_link_when_no_page_url(self):
        card = self._build(page_url=None, page_id=None)
        all_actions = [
            a for block in card["body"] if block.get("type") == "ActionSet"
            for a in block.get("actions", [])
        ]
        open_url_actions = [a for a in all_actions if a["type"] == "Action.OpenUrl"]
        self.assertEqual(len(open_url_actions), 0)

    def test_pre_results_summary_in_card(self):
        pre_results = [{"instance_name": "node-1", "output": "OK"}]
        card = self._build(pre_results=pre_results)
        all_text = json.dumps(card)
        self.assertIn("1 instance", all_text)


# ---------------------------------------------------------------------------
# Tests: _build_verification_card
# ---------------------------------------------------------------------------

class TestBuildVerificationCard(unittest.TestCase):

    def test_returns_adaptive_card(self):
        card = analyzer._build_verification_card(
            chain="avax", current_ver="1.14.1", latest_ver="1.14.2",
            instances=INSTANCES,
            results=[
                {"instance_name": "node-1", "output": "v1.14.2\nOK"},
                {"instance_name": "node-2", "output": "v1.14.2\nOK"},
            ],
        )
        self.assertEqual(card["type"], "AdaptiveCard")

    def test_success_count_displayed(self):
        card = analyzer._build_verification_card(
            chain="avax", current_ver="1.14.1", latest_ver="1.14.2",
            instances=INSTANCES,
            results=[
                {"instance_name": "node-1", "output": "v1.14.2"},
                {"instance_name": "node-2", "output": "(SSM error: timeout)"},
            ],
        )
        all_text = json.dumps(card)
        self.assertIn("1/2", all_text)

    def test_all_instance_names_present(self):
        card = analyzer._build_verification_card(
            chain="avax", current_ver="1.14.1", latest_ver="1.14.2",
            instances=INSTANCES,
            results=[
                {"instance_name": "node-1", "output": "OK"},
                {"instance_name": "node-2", "output": "OK"},
            ],
        )
        all_text = json.dumps(card)
        self.assertIn("node-1", all_text)
        self.assertIn("node-2", all_text)


# ---------------------------------------------------------------------------
# Tests: _run_pre_upgrade_on_instances
# ---------------------------------------------------------------------------

class TestRunPreUpgradeOnInstances(unittest.TestCase):

    def test_calls_ssm_for_each_instance(self):
        with patch.object(analyzer, "run_ssm_diagnostics", return_value="OK") as mock_ssm:
            results = analyzer._run_pre_upgrade_on_instances(INSTANCES, ["df -h"])
            self.assertEqual(mock_ssm.call_count, 2)
            self.assertEqual(results[0]["instance_name"], "node-1")
            self.assertEqual(results[0]["output"], "OK")
            self.assertEqual(results[1]["instance_name"], "node-2")

    def test_skips_instance_without_id(self):
        instances = [{"name": "node-1", "id": "i-aaa"}, {"name": "node-no-id", "id": ""}]
        with patch.object(analyzer, "run_ssm_diagnostics", return_value="OK") as mock_ssm:
            results = analyzer._run_pre_upgrade_on_instances(instances, ["df -h"])
            self.assertEqual(mock_ssm.call_count, 1)  # only node-1 has id
            skipped = next(r for r in results if r["instance_name"] == "node-no-id")
            self.assertIn("skipped", skipped["output"])

    def test_ssm_exception_doesnt_abort(self):
        with patch.object(analyzer, "run_ssm_diagnostics", side_effect=Exception("timeout")):
            results = analyzer._run_pre_upgrade_on_instances(INSTANCES, ["df -h"])
            self.assertEqual(len(results), 2)
            for r in results:
                self.assertIn("SSM error", r["output"])

    def test_empty_commands_returns_empty(self):
        results = analyzer._run_pre_upgrade_on_instances(INSTANCES, [])
        self.assertEqual(results, [])

    def test_results_preserve_instance_order(self):
        call_order = []
        def _ssm(inst_id, cmds, **kw):
            call_order.append(inst_id)
            return "OK"
        with patch.object(analyzer, "run_ssm_diagnostics", side_effect=_ssm):
            results = analyzer._run_pre_upgrade_on_instances(INSTANCES, ["ls"])
        self.assertEqual([r["instance_name"] for r in results], ["node-1", "node-2"])


# ---------------------------------------------------------------------------
# Tests: Notion search/create helpers (mocked urllib)
# ---------------------------------------------------------------------------

class TestNotionSearchPage(unittest.TestCase):

    def _mock_urlopen(self, data):
        m = MagicMock()
        m.__enter__ = MagicMock(return_value=m)
        m.__exit__ = MagicMock(return_value=False)
        m.read = MagicMock(return_value=json.dumps(data).encode())
        return m

    def test_returns_page_id_when_title_matches(self):
        resp_data = {
            "results": [{
                "id": "page-abc",
                "url": "https://notion.so/page-abc",
                "properties": {
                    "title": {"title": [{"plain_text": "Avalanche Upgrade Plan 1.14.1 → 1.14.2"}]}
                },
            }]
        }
        with patch("urllib.request.urlopen", return_value=self._mock_urlopen(resp_data)):
            page_id, page_url = analyzer._notion_search_page(
                "token", "Avalanche Upgrade Plan 1.14.1 → 1.14.2"
            )
        self.assertEqual(page_id, "page-abc")
        self.assertEqual(page_url, "https://notion.so/page-abc")

    def test_returns_none_when_title_doesnt_match(self):
        resp_data = {
            "results": [{
                "id": "page-abc",
                "url": "https://notion.so/page-abc",
                "properties": {
                    "title": {"title": [{"plain_text": "Other Page"}]}
                },
            }]
        }
        with patch("urllib.request.urlopen", return_value=self._mock_urlopen(resp_data)):
            page_id, page_url = analyzer._notion_search_page(
                "token", "Avalanche Upgrade Plan 1.14.1 → 1.14.2"
            )
        self.assertIsNone(page_id)
        self.assertIsNone(page_url)

    def test_returns_none_on_network_error(self):
        with patch("urllib.request.urlopen", side_effect=Exception("network error")):
            page_id, page_url = analyzer._notion_search_page("token", "any title")
        self.assertIsNone(page_id)
        self.assertIsNone(page_url)

    def test_returns_none_on_empty_results(self):
        with patch("urllib.request.urlopen", return_value=self._mock_urlopen({"results": []})):
            page_id, page_url = analyzer._notion_search_page("token", "any title")
        self.assertIsNone(page_id)


if __name__ == "__main__":
    unittest.main(verbosity=2)
