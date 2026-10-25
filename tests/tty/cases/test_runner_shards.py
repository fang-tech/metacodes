"""run_tty_tests 的分片逻辑单测(离线,不起二进制,bin_path 未用)。

CI 把 TTY 套件按 `--shard K/N` 拆到多台 runner(doc/CI_DESIGN.md §4)。分片漏一个用例
就是一个永远不跑却也不报错的用例,所以这里钉死:N 片恰好划分全表、互不重叠。
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from run_tty_tests import load_cases, parse_shard, select_shard  # noqa: E402


def test_shards_partition_the_real_case_list(bin_path):
    names = [name for name, _ in load_cases()]
    for count in (1, 2, 3, 4, 6, 7):
        seen = []
        for index in range(1, count + 1):
            seen.extend(name for name, _ in select_shard([(n, None) for n in names], index, count))
        assert sorted(seen) == sorted(names), f"{count} 片没有恰好划分用例表"
        assert len(seen) == len(set(seen)), f"{count} 片有重叠"


def test_shard_spec_is_validated(bin_path):
    assert parse_shard("1/1") == (1, 1)
    assert parse_shard("3/4") == (3, 4)
    for bad in ("0/3", "4/3", "1/0", "1", "a/b", "1/2/3", "", "-1/2"):
        assert parse_shard(bad) is None, bad
