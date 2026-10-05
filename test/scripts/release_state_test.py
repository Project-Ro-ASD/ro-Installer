#!/usr/bin/env python3

from __future__ import annotations

import importlib.util
import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
MODULE_PATH = ROOT / "scripts" / "release-state.py"
SPEC = importlib.util.spec_from_file_location("release_state", MODULE_PATH)
assert SPEC and SPEC.loader
release_state = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(release_state)


class ReleaseStateTests(unittest.TestCase):
    def test_absent_tag(self):
        self.assertEqual(
            release_state.classify(
                [{"databaseId": 10, "tagName": "v1.0.0", "isDraft": False}],
                "v2.0.0",
            ),
            {"state": "absent", "release_id": None},
        )

    def test_existing_draft(self):
        self.assertEqual(
            release_state.classify(
                [{"databaseId": 42, "tagName": "v2.0.0", "isDraft": True}],
                "v2.0.0",
            ),
            {"state": "draft", "release_id": 42},
        )

    def test_existing_published_release(self):
        self.assertEqual(
            release_state.classify(
                [{"databaseId": 43, "tagName": "v2.0.0", "isDraft": False}],
                "v2.0.0",
            ),
            {"state": "published", "release_id": 43},
        )

    def test_duplicate_tag_fails_closed(self):
        with self.assertRaisesRegex(ValueError, "multiple releases"):
            release_state.classify(
                [
                    {"databaseId": 1, "tagName": "v2.0.0", "isDraft": True},
                    {"databaseId": 2, "tagName": "v2.0.0", "isDraft": False},
                ],
                "v2.0.0",
            )

    def test_invalid_release_id_fails_closed(self):
        with self.assertRaisesRegex(ValueError, "databaseId"):
            release_state.classify(
                [{"databaseId": None, "tagName": "v2.0.0", "isDraft": True}],
                "v2.0.0",
            )

    def test_invalid_draft_flag_fails_closed(self):
        with self.assertRaisesRegex(ValueError, "isDraft"):
            release_state.classify(
                [{"databaseId": 1, "tagName": "v2.0.0", "isDraft": "false"}],
                "v2.0.0",
            )


if __name__ == "__main__":
    unittest.main()
