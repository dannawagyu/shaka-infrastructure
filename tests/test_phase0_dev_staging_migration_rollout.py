import unittest
from pathlib import Path


RUNBOOK = Path("docs/operations/phase0-dev-staging-migration-rollout.md")


class Phase0DevStagingMigrationRolloutTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.content = RUNBOOK.read_text(encoding="utf-8")
        cls.lower_content = cls.content.lower()

    def test_runbook_exists_and_limits_scope_to_phase0(self):
        self.assertIn("Phase 0 readiness check only", self.content)
        self.assertIn("dev/staging", self.lower_content)
        self.assertIn("v1-to-v2 data rewrite", self.lower_content)

    def test_runbook_forbids_production_side_effects(self):
        required_forbidden_items = [
            "production apply",
            "production terraform state mutation",
            "production secret changes",
            "production database migration",
        ]
        for item in required_forbidden_items:
            with self.subTest(item=item):
                self.assertIn(item, self.lower_content)

    def test_runbook_requires_backup_rollback_and_observability_checks(self):
        required_sections = [
            "backup checklist",
            "rollback decision matrix",
            "observability checklist",
            "./scripts/validate-terraform-ci.sh",
            "python3 -m unittest discover -s tests -v",
        ]
        for section in required_sections:
            with self.subTest(section=section):
                self.assertIn(section, self.lower_content)


if __name__ == "__main__":
    unittest.main()
