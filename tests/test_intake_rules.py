import unittest
from datetime import datetime, timedelta, timezone

import intake_rules as rules


class IntakeRulesTest(unittest.TestCase):
    def test_request_types_and_chinese_aliases(self):
        self.assertEqual(rules.normalize_request_type("故障"), "incident")
        self.assertEqual(rules.normalize_request_type("客户需求"), "customer")
        self.assertEqual(rules.normalize_request_type("sales"), "sales")
        self.assertEqual(rules.normalize_request_type("内部改进"), "improvement")
        self.assertEqual(rules.normalize_request_type("临时事项"), "temporary")
        self.assertEqual(rules.normalize_request_type("unknown"), "temporary")

    def test_sla_deadlines_by_type(self):
        start = datetime(2026, 11, 5, 9, tzinfo=timezone.utc)
        self.assertEqual(rules.sla_due_at("incident", start), start + timedelta(hours=2))
        self.assertEqual(rules.sla_due_at("customer", start), start + timedelta(hours=24))
        self.assertEqual(rules.sla_due_at("improvement", start), start + timedelta(hours=72))
        self.assertEqual(rules.sla_due_at("temporary", start), start + timedelta(hours=24))

    def test_priority_score_is_explainable(self):
        result = rules.priority_score({
            "business_value": 4, "urgency": 5, "risk": 3,
            "dependency_impact": 2, "effort": 1,
        })
        self.assertEqual(result["score"], 51)
        self.assertEqual([item["key"] for item in result["factors"]],
                         ["business_value", "urgency", "risk",
                          "dependency_impact", "effort"])
        self.assertTrue(all(item["reason"] for item in result["factors"]))
        self.assertIn("51", result["explanation"])

    def test_priority_inputs_are_clamped_and_invalid_zeroed(self):
        result = rules.priority_score({
            "business_value": 99, "urgency": -2, "risk": "bad",
            "dependency_impact": None, "effort": 4,
        })
        self.assertEqual(result["score"], 17)
        self.assertEqual(result["factors"][0]["value"], 5)
        self.assertEqual(result["factors"][1]["value"], 0)

    def test_priority_override_requires_reason(self):
        invalid = rules.priority_override(90, "")
        valid = rules.priority_override(90, "CEO requested")
        self.assertFalse(invalid["valid"])
        self.assertTrue(valid["valid"])
        self.assertEqual(valid["score"], 90)
        self.assertEqual(valid["reason"], "CEO requested")

    def test_external_submission_requires_contact_and_consent(self):
        data = {
            "title": "支付页面报错", "detail": "客户在支付后看到空白页面",
            "request_type": "incident", "requester_name": "王女士",
            "requester_email": "bad-email", "consent": False,
        }
        result = rules.validate_submission(data, external=True)
        self.assertFalse(result["valid"])
        self.assertIn("email", result["reason"])
        self.assertIn("consent", result["reason"])

    def test_internal_submission_can_use_profile_identity(self):
        result = rules.validate_submission({
            "title": "补充交付说明", "detail": "把部署说明补到项目文档",
            "request_type": "improvement",
        }, external=False)
        self.assertTrue(result["valid"])

    def test_duplicate_similarity_handles_chinese_and_english(self):
        self.assertGreater(
            rules.similarity_score("支付页面报错无法完成付款", "支付页面报错，付款失败"),
            0.45,
        )
        self.assertGreater(
            rules.similarity_score("Payment page fails", "payment page failure"),
            0.45,
        )
        self.assertLess(
            rules.similarity_score("支付页面报错", "年度预算审批"),
            0.2,
        )

    def test_duplicate_candidates_are_ranked_and_limited(self):
        candidates = [
            {"id": "a", "title": "支付页面报错", "detail": "付款失败"},
            {"id": "b", "title": "年度预算", "detail": "预算审批"},
            {"id": "c", "title": "支付页面错误", "detail": "付款失败"},
        ]
        found = rules.rank_duplicates("支付页面报错", "付款失败", candidates, limit=2)
        self.assertEqual([row["id"] for row in found], ["a", "c"])
        self.assertGreaterEqual(found[0]["similarity"], found[1]["similarity"])

    def test_public_view_filters_internal_messages(self):
        messages = [
            {"body": "已受理", "visibility": "public"},
            {"body": "客户预算不够", "visibility": "internal"},
            {"body": "预计明天处理", "visibility": "public", "internal_note": True},
        ]
        visible = rules.public_messages(messages)
        self.assertEqual([row["body"] for row in visible], ["已受理"])

    def test_public_status_payload_has_no_internal_fields(self):
        payload = rules.public_status_payload({
            "tracking_code": "AB12CD34", "status": "triage",
            "request_type": "customer", "title": "官网改版",
            "messages": [{"body": "已收到", "visibility": "public"}],
            "owner_profile_id": "secret-user", "internal_note": "margin",
            "project_id": "secret-project",
        })
        self.assertEqual(payload["tracking_code"], "AB12CD34")
        self.assertNotIn("owner_profile_id", payload)
        self.assertNotIn("internal_note", payload)
        self.assertNotIn("project_id", payload)
        self.assertEqual(len(payload["messages"]), 1)

    def test_sla_escalation_only_for_open_overdue_requests(self):
        now = datetime(2026, 11, 5, 12, tzinfo=timezone.utc)
        self.assertTrue(rules.should_escalate(
            {"status": "submitted", "sla_due_at": now - timedelta(minutes=1)}, now
        ))
        self.assertFalse(rules.should_escalate(
            {"status": "triage", "sla_due_at": now - timedelta(minutes=1)}, now
        ))
        self.assertFalse(rules.should_escalate(
            {"status": "submitted", "sla_due_at": now + timedelta(minutes=1)}, now
        ))

    def test_conversion_payload_validation(self):
        self.assertTrue(rules.validate_conversion("project", {"name": "官网改造"})["valid"])
        self.assertTrue(rules.validate_conversion("task", {
            "title": "修复支付", "project_id": "p1", "employee_id": "u1",
            "plan_date": "2026-11-06",
        })["valid"])
        self.assertTrue(rules.validate_conversion("presales", {"owner_id": "u1"})["valid"])
        self.assertFalse(rules.validate_conversion("task", {"title": "x"})["valid"])
        self.assertFalse(rules.validate_conversion("unknown", {})["valid"])

    def test_message_validation_and_visibility(self):
        self.assertTrue(rules.validate_message("已收到，我们会在今天处理", True)["valid"])
        self.assertFalse(rules.validate_message("", True)["valid"])
        self.assertFalse(rules.validate_message("x" * 4001, True)["valid"])


if __name__ == "__main__":
    unittest.main()
