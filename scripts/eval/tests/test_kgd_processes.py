"""A test that runs the real binary must not leave TinyKG services behind.

A session starts its install's TinyKG service (`metacodes --state-dir <root>
kgd`) when it needs one, and the service outlives the session on purpose. The
stand-ins here are sleeping processes whose command line ends the same way,
so these tests need no binary: they pin the helpers in
scripts/eval/kgd_processes.py and the per-scenario teardown in
tests/e2e/lib.sh, on both sides (what must be stopped, and what must be left
alone).
"""

import os
import subprocess
import sys
import tempfile
import textwrap
import time
import unittest
from pathlib import Path

from scripts.eval.kgd_processes import (
    live_kgd_under,
    stop_kgd_under,
    temporary_directory_without_kgd,
)

ROOT = Path(__file__).resolve().parents[3]


def _fake_kgd(state_dir: Path, *tail: str) -> subprocess.Popen:
    """A process whose command line reads like `... --state-dir <dir> kgd`;
    `tail` replaces the trailing `kgd` (autostart appends `--config <path>`
    for a METACODES_KG_CONFIG file, and a session has no `kgd` at all)."""
    return subprocess.Popen(
        [sys.executable, "-c", "import time; time.sleep(120)", "--state-dir", str(state_dir), *(tail or ("kgd",))],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )


def _alive(pid: int) -> bool:
    """Whether `pid` still runs (the spawned stand-ins are not our children,
    so a stopped one is gone, not a zombie)."""
    try:
        os.kill(pid, 0)
    except OSError:
        return False
    return True


def _wait_listed(root: Path, pid: int) -> None:
    deadline = time.monotonic() + 5
    while pid not in live_kgd_under(root) and time.monotonic() < deadline:
        time.sleep(0.05)


@unittest.skipUnless(os.name == "posix", "reads the process table with ps")
class KgdProcessesTest(unittest.TestCase):
    def setUp(self):
        self._spawned = []

    def tearDown(self):
        for process in self._spawned:
            if process.poll() is None:
                process.kill()
            process.wait(timeout=5)

    def _spawn(self, state_dir: Path, *tail: str) -> subprocess.Popen:
        process = _fake_kgd(state_dir, *tail)
        self._spawned.append(process)
        return process

    def test_finds_and_stops_only_the_services_under_the_root(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            inside = self._spawn(root / "run" / ".home" / ".metacodes")
            outside = self._spawn(root / "elsewhere" / ".metacodes")
            _wait_listed(root / "run", inside.pid)
            self.assertEqual(live_kgd_under(root / "run"), [inside.pid])
            self.assertEqual(stop_kgd_under(root / "run"), [inside.pid])
            inside.wait(timeout=5)
            self.assertEqual(live_kgd_under(root / "run"), [])
            self.assertIsNone(outside.poll(), "a service outside the root was stopped")
            # A sibling whose name only starts with the root's is not under it.
            self.assertEqual(live_kgd_under(root / "else"), [])

    def test_a_service_with_its_own_configuration_is_found_and_a_session_is_not(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            configured = self._spawn(root / ".metacodes", "kgd", "--config", str(root / "kg config.json"))
            session = self._spawn(root / ".metacodes", "-p", "hello")
            _wait_listed(root, configured.pid)
            self.assertEqual(live_kgd_under(root), [configured.pid])
            self.assertEqual(stop_kgd_under(root), [configured.pid])
            configured.wait(timeout=5)
            self.assertIsNone(session.poll(), "a process that is not a service was stopped")

    def test_the_guarded_directory_fails_a_run_that_leaks_and_cleans_up(self):
        with self.assertRaises(AssertionError) as caught:
            with temporary_directory_without_kgd() as directory:
                leaked = self._spawn(Path(directory) / "home" / ".metacodes")
                _wait_listed(Path(directory), leaked.pid)
        self.assertIn("METACODES_KG_AUTOSTART=0", str(caught.exception))
        leaked.wait(timeout=5)  # stopped on the way out

    def test_the_guarded_directory_passes_a_clean_run_and_keeps_the_body_error(self):
        with temporary_directory_without_kgd() as directory:
            Path(directory, "work").mkdir()
        with self.assertRaises(ValueError):
            with temporary_directory_without_kgd() as directory:
                leaked = self._spawn(Path(directory) / ".metacodes")
                _wait_listed(Path(directory), leaked.pid)
                raise ValueError("the body's own failure wins")
        leaked.wait(timeout=5)  # still stopped

    def test_e2e_scenario_teardown_stops_the_service_in_its_fake_home(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            scenario = root / "kgd-teardown.txt"
            scenario.write_text("start a service and leave\n", encoding="utf-8")
            pid_file = root / "pids"
            fake_binary = root / "fake-metacodes"
            # The stand-in for a session that autostarted kgd in its HOME, plus
            # one service of another state root that the teardown must keep.
            fake_binary.write_text(
                textwrap.dedent(
                    f"""\
                    #!{sys.executable} -I
                    import os, subprocess, sys
                    def spawn(state_dir):
                        return subprocess.Popen(
                            [sys.executable, "-c", "import time; time.sleep(120)", "--state-dir", state_dir, "kgd"],
                            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                            stderr=subprocess.DEVNULL, start_new_session=True,
                        ).pid
                    def spawn_tail(state_dir, *tail):
                        return subprocess.Popen(
                            [sys.executable, "-c", "import time; time.sleep(120)", "--state-dir", state_dir, *tail],
                            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                            stderr=subprocess.DEVNULL, start_new_session=True,
                        ).pid
                    state = os.path.join(os.environ["HOME"], ".metacodes")
                    mine = spawn(state)
                    configured = spawn_tail(state, "kgd", "--config", os.path.join(state, "kg", "custom.json"))
                    session = spawn_tail(state, "-p", "hello")
                    other = spawn({str(root / "other-install" / ".metacodes")!r})
                    with open({str(pid_file)!r}, "w") as handle:
                        handle.write(f"{{mine}} {{configured}} {{session}} {{other}}")
                    sys.stdin.read()
                    """
                ),
                encoding="utf-8",
            )
            fake_binary.chmod(0o700)
            workdir = root / "run" / "kgd_teardown"
            logfile = root / "run" / "kgd_teardown.log"
            script = """
set -e
source "$1/tests/e2e/lib.sh"
BIN="$2"
E2E_HOST_HOME=""
run_session "$3" "$4" "$5" "$6" "$7"
"""
            completed = subprocess.run(
                [
                    "/bin/bash", "-c", script, "kgd-teardown", str(ROOT), str(fake_binary),
                    str(scenario), str(workdir), str(logfile), str(root / "run" / "debug.log"),
                    str(root / "missing.conf"),
                ],
                cwd=ROOT,
                env={"PATH": os.defpath, "HOME": str(root)},
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                timeout=60,
                check=False,
            )
            mine, configured, session, other = (int(pid) for pid in pid_file.read_text(encoding="utf-8").split())
            try:
                self.assertEqual(completed.returncode, 0, completed.stderr)
                # run_session reports the scenario's exit code on stdout, alone.
                self.assertEqual(completed.stdout.strip(), "0")
                self.assertEqual(live_kgd_under(workdir), [], logfile.read_text(encoding="utf-8"))
                self.assertIn("stopped the TinyKG service", logfile.read_text(encoding="utf-8"))
                self.assertEqual(live_kgd_under(root / "other-install"), [other], "another state root's service was stopped")
                for pid in (mine, configured):
                    self.assertFalse(_alive(pid), f"the scenario's service {pid} is still running")
                self.assertTrue(_alive(session), "a process in the fake HOME that is not a service was stopped")
            finally:
                for pid in (mine, configured, session, other):
                    try:
                        os.kill(pid, 9)
                    except OSError:
                        pass


if __name__ == "__main__":
    unittest.main()
