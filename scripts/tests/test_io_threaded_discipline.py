"""Every ``std.Io.Threaded`` in this repository is created through
``platform.signal.threadedIo``.

``std.Io.Threaded.init`` replaces SIGPIPE's disposition with a do-nothing
handler installed without SA_RESTART. Unlike SIG_IGN, a handler gets the signal
delivered, so a SIGPIPE (on macOS a write to a closed socket signals the whole
process) turns any thread's blocked recv/poll/accept/waitpid into EINTR.
``threadedIo`` keeps SIGPIPE ignored where the process asked for that (see
src/platform/signal.zig); one direct ``init`` call is enough to undo it.
"""
from __future__ import annotations

import re
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
# The wrapper itself, plus its control tests that show what std does alone.
ALLOWED = {Path("src/platform/signal.zig")}
# Third-party trees are not ours to change; build output is not source.
SKIPPED_DIRS = {".git", ".zig-cache", "zig-out", "deps", "vendor", ".claude", "node_modules"}
# Also catches `const Threaded = std.Io.Threaded;` followed by `Threaded.init(`.
DIRECT_INIT = re.compile(r"\bThreaded\s*\.\s*init\s*\(")


def violations(root: Path) -> list[str]:
    """`path:line` for every direct Threaded.init call in a Zig file under root."""
    found = []
    for path in sorted(root.rglob("*.zig")):
        relative = path.relative_to(root)
        if SKIPPED_DIRS.intersection(relative.parts) or relative in ALLOWED:
            continue
        for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            code = line.split("//", 1)[0]
            if DIRECT_INIT.search(code):
                found.append(f"{relative.as_posix()}:{number}")
    return found


class IoThreadedDisciplineTest(unittest.TestCase):
    def test_repository_creates_io_threaded_only_through_threaded_io(self):
        self.assertEqual(
            violations(ROOT),
            [],
            "create std.Io.Threaded with @import(\"platform\").signal.threadedIo "
            "(see src/platform/signal.zig)",
        )

    def test_scanner_reports_direct_and_aliased_calls_but_not_comments(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "src").mkdir()
            (root / "src" / "direct.zig").write_text(
                "var io = std.Io.Threaded.init(gpa, .{});\n", encoding="utf-8"
            )
            (root / "src" / "aliased.zig").write_text(
                "const Threaded = std.Io.Threaded;\nvar io = Threaded.init(gpa, .{});\n",
                encoding="utf-8",
            )
            (root / "src" / "fine.zig").write_text(
                "// std.Io.Threaded.init is wrapped\n"
                "var io = @import(\"platform\").signal.threadedIo(gpa, .{});\n"
                "const single = std.Io.Threaded.init_single_threaded;\n",
                encoding="utf-8",
            )
            (root / "vendor").mkdir()
            (root / "vendor" / "third_party.zig").write_text(
                "var io = std.Io.Threaded.init(gpa, .{});\n", encoding="utf-8"
            )
            self.assertEqual(violations(root), ["src/aliased.zig:2", "src/direct.zig:1"])


if __name__ == "__main__":
    unittest.main()
