import re
import shlex
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


def checklist_commands():
    text = (ROOT / "AGENTS.md").read_text(encoding="utf-8")
    block = re.search(r"Before submitting:\s*\n\s*```sh\n(.*?)\n```", text, re.S)
    if not block:
        raise AssertionError("AGENTS.md has no Before submitting shell block")
    return [line.strip() for line in block.group(1).splitlines() if line.strip()]


def ci_commands():
    lines = (ROOT / ".github" / "workflows" / "ci.yml").read_text(encoding="utf-8").splitlines()
    commands = []
    index = 0
    while index < len(lines):
        line = lines[index]
        match = re.match(r"^\s*run:\s*(.*)$", line)
        if match:
            value = match.group(1)
            if value in ("|", ">-"):
                index += 1
                while index < len(lines) and (not lines[index].strip() or len(lines[index]) - len(lines[index].lstrip()) > len(line) - len(line.lstrip())):
                    if lines[index].strip():
                        commands.append(lines[index].strip())
                    index += 1
                continue
            commands.append(value.strip())
        index += 1
    return commands


def normalized_words(command):
    words = shlex.split(command)
    if words and words[0] in ("python", "python3"):
        words[0] = "python"
    return words


class GateManifestTest(unittest.TestCase):
    def test_checklist_commands_are_present_in_ci(self):
        ci = [normalized_words(command) for command in ci_commands()]
        for expected in checklist_commands():
            words = normalized_words(expected)
            self.assertTrue(any(actual[: len(words)] == words for actual in ci), "missing checklist command: %s" % expected)

    def test_the_posix_legs_run_both_halves_of_the_suite_alike(self):
        """`zig build test` is its two halves (build.zig), and the POSIX gate
        legs run one each (doc/CI_DESIGN.md §4): both must run, with the same
        options, or the split drops part of the suite."""
        halves = {}
        for command in ci_commands():
            words = normalized_words(command)
            if words[:2] == ["zig", "build"] and len(words) > 2 and words[2] in ("test:units", "test:product"):
                halves.setdefault(words[2], []).append(words[3:])
        self.assertEqual(sorted(halves), ["test:product", "test:units"])
        self.assertEqual(len(halves["test:units"]), 1, halves)
        self.assertEqual(halves["test:units"], halves["test:product"])

    def test_the_test_step_is_exactly_its_two_halves(self):
        build = (ROOT / "build.zig").read_text(encoding="utf-8")
        self.assertIn('const units_test_step = b.step("test:units",', build)
        self.assertIn('const product_test_step = b.step("test:product",', build)
        self.assertEqual(re.findall(r"\btest_step\.dependOn\((\w+)\)", build), ["units_test_step", "product_test_step"])
        self.assertEqual(len(re.findall(r"\btest_step\.dependOn\(", build)), 2)


if __name__ == "__main__":
    unittest.main()
