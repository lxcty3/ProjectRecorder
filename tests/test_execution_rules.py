import unittest

from execution_rules import (
    acceptance_result,
    change_requires_approval,
    dependency_cycle,
    downstream_delay,
    downstream_impact,
    is_final_completion_allowed,
    normalize_risk,
    normalize_urgency,
    review_acceptance,
    validate_change_request,
)


class ExecutionRulesTest(unittest.TestCase):
    def test_acceptance_requires_evidence_and_reviewer(self):
        self.assertFalse(acceptance_result("", "u1", "u2")["valid"])
        self.assertFalse(acceptance_result("done", "u1", "u1")["valid"])
        self.assertTrue(acceptance_result("done", "u1", "u2")["valid"])

    def test_acceptance_requires_criteria_when_provided(self):
        self.assertFalse(
            acceptance_result("done", "u1", "u2", criteria="")["valid"]
        )
        self.assertTrue(
            acceptance_result("done", "u1", "u2", criteria="tests pass")["valid"]
        )

    def test_acceptance_review_states_cannot_skip_to_complete(self):
        pending = review_acceptance("pending", "pending")
        self.assertTrue(pending["valid"])
        self.assertEqual(pending["status"], "pending")
        self.assertFalse(review_acceptance("pending", "completed")["valid"])
        self.assertEqual(
            review_acceptance("pending", "accepted")["status"], "accepted"
        )
        self.assertEqual(
            review_acceptance("pending", "rework")["status"], "rework"
        )
        self.assertFalse(review_acceptance("accepted", "rework")["valid"])

    def test_final_completion_requires_accepted_valid_record(self):
        base = {
            "status": "accepted",
            "criteria": "acceptance criteria",
            "evidence": "delivery evidence",
            "submitter_id": "u1",
            "reviewer_id": "u2",
        }
        self.assertTrue(is_final_completion_allowed(base)["valid"])
        self.assertFalse(
            is_final_completion_allowed({**base, "status": "pending"})["valid"]
        )
        self.assertFalse(
            is_final_completion_allowed({**base, "evidence": ""})["valid"]
        )
        self.assertFalse(
            is_final_completion_allowed({**base, "reviewer_id": "u1"})["valid"]
        )

    def test_downstream_delay(self):
        self.assertEqual(downstream_delay(3, 2), 5)
        self.assertEqual(downstream_delay(-8, 2), 0)

    def test_dependency_cycle_detection(self):
        edges = {"a": ["b"], "b": ["c"], "c": []}
        self.assertTrue(dependency_cycle(edges, "c", "a"))
        self.assertFalse(dependency_cycle(edges, "c", "d"))

    def test_downstream_impact_is_recursive_and_cumulative(self):
        edges = {
            "a": [{"task_id": "b", "lag_days": 2}],
            "b": [{"task_id": "c", "lag_days": 1}],
            "d": [{"task_id": "b", "lag_days": 4}],
        }
        impact = downstream_impact(edges, "c", 3)
        self.assertEqual(
            impact,
            [
                {"task_id": "b", "delay_days": 4},
                {"task_id": "a", "delay_days": 6},
                {"task_id": "d", "delay_days": 8},
            ],
        )

    def test_change_approval(self):
        self.assertTrue(change_requires_approval(60000, 2, "严重"))
        self.assertTrue(change_requires_approval(1000, 4, "健康"))
        self.assertTrue(change_requires_approval(1000, 0, "风险"))
        self.assertTrue(
            change_requires_approval(
                1000, 0, "健康", urgency="urgent", cross_department=True
            )
        )
        self.assertFalse(change_requires_approval(1000, 0, "健康"))

    def test_risk_and_urgency_aliases_normalize_before_impact_checks(self):
        self.assertEqual(normalize_risk('高风险'), 'severe')
        self.assertEqual(normalize_risk('严重'), 'severe')
        self.assertEqual(normalize_risk('风险'), 'risk')
        self.assertEqual(normalize_urgency('紧急'), 'urgent')
        self.assertEqual(normalize_urgency('严重'), 'critical')
        self.assertEqual(normalize_urgency('高'), 'high')
        self.assertTrue(change_requires_approval(1, 0, '高风险'))
        self.assertTrue(change_requires_approval(1, 0, '健康', urgency='紧急'))
        self.assertTrue(change_requires_approval(1, 0, '健康', urgency='高'))

    def test_change_request_captures_all_required_impacts(self):
        self.assertFalse(
            validate_change_request(
                {
                    "scope": "",
                    "reason": "client request",
                    "urgency": "normal",
                    "schedule_impact_days": 2,
                    "cost_impact": 100,
                    "resource_impact": "one engineer",
                }
            )["valid"]
        )
        self.assertFalse(
            validate_change_request(
                {
                    "scope": "expand API",
                    "reason": "",
                    "urgency": "normal",
                    "schedule_impact_days": 2,
                    "cost_impact": 100,
                    "resource_impact": "one engineer",
                }
            )["valid"]
        )
        self.assertTrue(
            validate_change_request(
                {
                    "scope": "expand API",
                    "reason": "client request",
                    "urgency": "high",
                    "schedule_impact_days": 2,
                    "cost_impact": 100,
                    "resource_impact": "one engineer",
                }
            )["valid"]
        )


if __name__ == "__main__":
    unittest.main()
