import unittest

from operations_rules import capacity_gap, performance_score, project_margin


class OperationsRulesTest(unittest.TestCase):
    def test_margin_exposes_full_economics_contract(self):
        result = project_margin(
            contract=100000,
            invoiced=60000,
            cost=20000,
            committed=10000,
            collected=45000,
            labor_cost=35000,
        )
        self.assertEqual(result["contract_amount"], 100000)
        self.assertEqual(result["invoiced_amount"], 60000)
        self.assertEqual(result["collected_amount"], 45000)
        self.assertEqual(result["outsourced_committed"], 10000)
        self.assertEqual(result["labor_cost"], 35000)
        self.assertEqual(result["projected_completion_cost"], 65000)
        self.assertEqual(result["projected_margin"], 35000)
        self.assertEqual(result["projected_margin_percent"], 35.0)
        self.assertEqual(result["collection_gap"], 55000)

    def test_margin_plan_style_call_uses_labor_plus_committed_cost(self):
        result = project_margin(100000, 20000, 45000, 10000)
        self.assertEqual(result["projected_completion_cost"], 55000)
        self.assertEqual(result["projected_margin"], 45000)
        self.assertEqual(result["projected_margin_percent"], 45.0)

    def test_margin_accepts_explicit_projected_completion_cost(self):
        result = project_margin(
            contract=100000,
            invoiced=20000,
            cost=45000,
            committed=10000,
            projected_completion_cost=75000,
        )
        self.assertEqual(result["projected_completion_cost"], 75000)
        self.assertEqual(result["projected_margin"], 25000)
        self.assertEqual(result["projected_margin_percent"], 25.0)

    def test_margin_rejects_negative_display_but_clamps_costs(self):
        result = project_margin(100000, -5000, -20000, -10000, collected=-1)
        self.assertEqual(result["projected_completion_cost"], 0)
        self.assertEqual(result["projected_margin"], 100000)
        self.assertEqual(result["collection_gap"], 100000)

    def test_capacity_gap_uses_positive_shortfall(self):
        self.assertEqual(capacity_gap([40, 32, 24], [30, 35, 30]), 1)
        self.assertEqual(capacity_gap([40], [80]), 0)

    def test_capacity_gap_plan_style_call(self):
        self.assertEqual(capacity_gap([40, 32, 24], [30, 35, 30]), 1)

    def test_performance_score_is_evidence_based(self):
        score = performance_score(
            on_time=0.9,
            first_pass=0.8,
            rework=0.1,
            collaboration=4.5,
            complexity=3.0,
            business_contribution=4.0,
        )
        self.assertGreater(score, 70)
        self.assertLessEqual(score, 100)

    def test_complexity_and_business_contribution_change_score(self):
        base = performance_score(0.9, 0.8, 0.1, 4.5, 0, 0)
        stronger = performance_score(0.9, 0.8, 0.1, 4.5, 5, 5)
        self.assertGreater(stronger, base)

    def test_performance_score_is_bounded_and_never_negative(self):
        self.assertEqual(performance_score(2, 2, -1, 9, 9, 9), 100)
        self.assertEqual(performance_score(-1, -1, 2, -4, -3, -2), 0)

    def test_performance_score_does_not_mutate_inputs_or_publish_wage(self):
        inputs = {
            "on_time": 0.8,
            "first_pass": 0.7,
            "rework": 0.2,
            "collaboration": 4.0,
        }
        score = performance_score(**inputs)
        self.assertIsInstance(score, float)
        self.assertEqual(inputs["on_time"], 0.8)
        self.assertNotIn("wage", str(score).lower())
        self.assertNotIn("promotion", str(score).lower())


if __name__ == "__main__":
    unittest.main()
