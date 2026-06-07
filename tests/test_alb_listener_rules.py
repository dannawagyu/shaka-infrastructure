#!/usr/bin/env python3
"""Static contract checks for Shaka production ALB listener rules."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
ALB_TF = ROOT / "terraform" / "environments" / "prod" / "alb.tf"


def _read() -> str:
    return ALB_TF.read_text(encoding="utf-8")


def _iter_listener_rule_blocks(text: str):
    pattern = re.compile(
        r'resource\s+"aws_lb_listener_rule"\s+"([^"]+)"\s*\{',
        re.MULTILINE,
    )
    for match in pattern.finditer(text):
        start = match.end()
        depth = 1
        idx = start
        while idx < len(text) and depth > 0:
            char = text[idx]
            if char == "{":
                depth += 1
            elif char == "}":
                depth -= 1
            idx += 1
        yield match.group(1), text[start : idx - 1]


def _priority(block: str) -> int:
    match = re.search(r"priority\s*=\s*(\d+)", block)
    assert match, f"listener_rule missing priority: {block[:80]}"
    return int(match.group(1))


class ALBListenerRulesTest(unittest.TestCase):
    def setUp(self) -> None:
        self.assertTrue(ALB_TF.is_file(), "alb.tf must exist for ALB listener rule tests")
        self.text = _read()
        self.rules = dict(_iter_listener_rule_blocks(self.text))

    def test_listener_rules_have_unique_priorities_within_limit(self):
        priorities = [_priority(block) for block in self.rules.values()]
        self.assertEqual(
            len(priorities),
            len(set(priorities)),
            f"ALB listener rule priorities must be unique: {sorted(priorities)}",
        )
        for priority in priorities:
            self.assertGreaterEqual(priority, 1)
            self.assertLessEqual(
                priority,
                50000,
                "ALB listener rule priorities must be within the AWS limit",
            )

    def test_no_scanner_block_rules(self):
        # The HTTPS listener is intentionally default-deny (default action = fixed-response 404).
        # Explicit scanner_block_* rules would not improve security and would create unbounded
        # pattern maintenance, so the design forbids them.
        scanner_rules = [name for name in self.rules if name.startswith("scanner_block_")]
        self.assertEqual(
            scanner_rules,
            [],
            f"scanner_block_* rules must not exist (listener is default-deny): {scanner_rules}",
        )

    def test_auth_path_is_forwarded(self):
        self.assertIn("forward_auth", self.rules)
        block = self.rules["forward_auth"]
        self.assertRegex(block, r'type\s*=\s*"forward"')
        self.assertIn("/api/v1/auth", block)
        self.assertRegex(block, re.compile(r'http_request_method\s*\{[^}]*POST', re.DOTALL))

    def test_health_path_is_forwarded_on_get(self):
        self.assertIn("forward_health", self.rules)
        block = self.rules["forward_health"]
        self.assertRegex(block, r'type\s*=\s*"forward"')
        self.assertIn("/actuator/health", block)
        self.assertRegex(block, re.compile(r'http_request_method\s*\{[^}]*GET', re.DOTALL))

    def test_protected_api_requires_authorization_bearer(self):
        self.assertIn("forward_protected_api", self.rules)
        block = self.rules["forward_protected_api"]
        self.assertRegex(block, r'type\s*=\s*"forward"')
        self.assertIn("/api/v1/*", block)
        self.assertRegex(
            block,
            re.compile(
                r'http_header\s*\{[^}]*http_header_name\s*=\s*"Authorization"[^}]*values\s*=\s*\[\s*"Bearer\s\*"\s*\]',
                re.DOTALL,
            ),
        )

    def test_unauthenticated_api_returns_401_not_404(self):
        self.assertIn("unauthenticated_api_401", self.rules)
        block = self.rules["unauthenticated_api_401"]
        self.assertRegex(block, r'type\s*=\s*"fixed-response"')
        self.assertRegex(block, r'status_code\s*=\s*"401"')
        self.assertIn("/api/v1/*", block)
        # Priority must come after forward_protected_api (400) but stay close to it.
        self.assertEqual(_priority(block), 401)
        forward_priority = _priority(self.rules["forward_protected_api"])
        self.assertLess(forward_priority, _priority(block))

    def test_https_listener_default_action_is_fixed_response_not_forward(self):
        match = re.search(
            r'resource\s+"aws_lb_listener"\s+"https"\s*\{(.*?)\n\}',
            self.text,
            re.DOTALL,
        )
        self.assertIsNotNone(match, "aws_lb_listener.https resource must exist")
        body = match.group(1)
        default_match = re.search(r'default_action\s*\{([^}]+)\}', body, re.DOTALL)
        self.assertIsNotNone(default_match, "https listener must define a default_action")
        default_body = default_match.group(1)
        self.assertRegex(default_body, r'type\s*=\s*"fixed-response"')
        self.assertRegex(default_body, r'status_code\s*=\s*"404"')
        self.assertNotRegex(default_body, r'type\s*=\s*"forward"')


if __name__ == "__main__":
    unittest.main()
