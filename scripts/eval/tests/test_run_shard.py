"""run_shard.py: the evaluation suite's shards partition its modules.

A module no shard selects never runs and never fails, so the partition is
checked on synthetic lists and on the suite's own module files.
"""
from __future__ import annotations

import unittest
from pathlib import Path

from scripts.eval.tests.run_shard import parse_shard, select_shard

HERE = Path(__file__).resolve().parent


class RunShardTest(unittest.TestCase):
    def test_the_shards_partition_any_list(self) -> None:
        for size in (0, 1, 2, 5, 53):
            items = list(range(size))
            for count in (1, 2, 3, 4, 7):
                with self.subTest(size=size, count=count):
                    picked = [item for index in range(1, count + 1) for item in select_shard(items, index, count)]
                    self.assertEqual(sorted(picked), items)

    def test_the_shards_partition_the_suites_modules(self) -> None:
        modules = sorted(path.name for path in HERE.glob("test*.py"))
        self.assertIn("test_run_shard.py", modules)
        for count in (2, 3):
            shards = [select_shard(modules, index, count) for index in range(1, count + 1)]
            self.assertEqual(sorted(name for shard in shards for name in shard), modules)
            self.assertTrue(all(shards))

    def test_the_shard_spec_is_validated(self) -> None:
        self.assertEqual(parse_shard("1/1"), (1, 1))
        self.assertEqual(parse_shard("2/3"), (2, 3))
        for bad in ("0/3", "4/3", "1/0", "1", "a/b", "1/2/3", "", "-1/2"):
            with self.subTest(bad=bad):
                self.assertIsNone(parse_shard(bad))


if __name__ == "__main__":
    unittest.main()
