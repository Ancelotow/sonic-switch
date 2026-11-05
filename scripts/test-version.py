#!/usr/bin/env python3
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("version", Path(__file__).with_name("bump-version.py"))
version = importlib.util.module_from_spec(spec)
spec.loader.exec_module(version)


class VersionTests(unittest.TestCase):
    def test_initial_release(self):
        self.assertEqual(version.next_version("0.1.4", [], "patch"), "0.1.5")

    def test_tag_comparison_is_numeric(self):
        self.assertEqual(version.next_version("0.1.4", ["v0.1.9", "v0.1.10"], "patch"), "0.1.11")

    def test_manual_minor_and_major(self):
        self.assertEqual(version.next_version("0.1.4", ["v0.2.9"], "minor"), "0.3.0")
        self.assertEqual(version.next_version("0.1.4", ["v0.2.9"], "major"), "1.0.0")

    def test_unrelated_tags_are_ignored(self):
        self.assertEqual(version.next_version("0.1.4", ["preview", "v9.0.0-beta.1", "other/v5.0.0"], "patch"), "0.1.5")

    def test_committed_version_can_exceed_tags(self):
        self.assertEqual(version.next_version("1.2.0", ["v0.1.10"], "patch"), "1.2.1")

    def test_invalid_input_is_rejected(self):
        for value in ["v1.2.3", "1.2", "1.2.3\n", "1.-2.3"]:
            with self.assertRaises(ValueError):
                version.parse_version(value)
        with self.assertRaises(ValueError):
            version.next_version("0.1.4", [], "other")


if __name__ == "__main__":
    unittest.main()
