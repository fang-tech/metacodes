"""The startup suggestion (`suggestion: explain or improve <file>`, from `git log -1
--name-only`) is printed before the first prompt, so the prompt waits for git. A slow
git must not hold it back: on a macOS runner `/usr/bin/git` is Xcode's shim, whose
first calls with a cold xcrun cache run `xcodebuild -license check` and `-find git`
(1.3-2.3 s), and the prompt used to wait up to 2 s for it. Past a short wait there is
no suggestion, but git is left to finish (a shim killed early never warms its cache,
and every later start would find it cold again) and stopped when the REPL ends. A git
that answers in time still gives a suggestion.

git runs with an empty environment (default search path), so a stand-in on PATH is
never reached. The slow git is a real one that blocks: the working directory's
`.git/HEAD` is a FIFO, and git waits in open() until the case opens the other end. The
git that answers is a repository with one commit. POSIX only: no FIFOs on Windows.
"""
import os
import shutil
import subprocess
import sys
import threading
import time

from tty_driver import READY, case_tmpdir, run

try:
    from e2e_helpers import SkipTest
except Exception:  # noqa: BLE001
    class SkipTest(Exception):
        pass

PLACEHOLDER = 'Try "fix typecheck errors"'.encode()


def _need_git():
    if sys.platform == "win32":
        raise SkipTest("the blocking repository needs a FIFO")
    if shutil.which("git") is None:
        raise SkipTest("git is not installed")


def _blocking_repo():
    """A directory git takes for a repository and then blocks in: HEAD is a FIFO."""
    repo = case_tmpdir("cc-tty-git-blocks-")
    os.makedirs(os.path.join(repo, ".git", "objects"))
    os.makedirs(os.path.join(repo, ".git", "refs"))
    os.mkfifo(os.path.join(repo, ".git", "HEAD"))
    return repo


def _git_waits_at(repo):
    """Whether a git is blocked opening the FIFO HEAD. Opening the writing end
    succeeds only then, and releases it: git reads an empty HEAD and gives up."""
    try:
        fd = os.open(os.path.join(repo, ".git", "HEAD"), os.O_WRONLY | os.O_NONBLOCK)
    except OSError:  # ENXIO: nobody has it open for reading
        return False
    os.close(fd)
    return True


def _one_commit_repo():
    """A repository whose last commit touched src/recent_change.zig."""
    repo = case_tmpdir("cc-tty-git-answers-")
    os.makedirs(os.path.join(repo, "src"))
    with open(os.path.join(repo, "src", "recent_change.zig"), "w", encoding="utf-8") as f:
        f.write("// one\n")
    git = ["git", "-C", repo, "-c", "user.name=tty", "-c", "user.email=tty@example.invalid"]
    for args in (["init", "-q"], ["add", "."], ["commit", "-q", "-m", "one"]):
        subprocess.run(git + args, check=True, capture_output=True)
    return repo


def _start(bin_path, cwd, events=()):
    """The output, and how long after the start the empty prompt came (its
    placeholder, what READY waits for; ESC[?2004h is not sent for a missing or
    dumb TERM)."""
    timeline = []
    started = time.monotonic()
    raw = run(bin_path, [READY, *events], timeline=timeline, cwd=cwd)
    prompt = raw.find(PLACEHOLDER)
    assert prompt >= 0, "the empty prompt never came"
    end = prompt + len(PLACEHOLDER)
    return raw, next(t for t, size in timeline if size >= end) - started


def test_a_slow_git_does_not_hold_back_the_first_prompt(bin_path):
    _need_git()
    repo = _blocking_repo()
    # 1.8 s in, after the prompt stopped waiting (and after the 1.5 s below): git must
    # still be running, not killed when the prompt gave up on it.
    waiting = []
    timer = threading.Timer(1.8, lambda: waiting.append(_git_waits_at(repo)))
    timer.start()
    try:
        raw, after = _start(bin_path, repo, ["strictsleep:2.0"])
    finally:
        timer.join()
    assert after < 1.5, f"the first prompt came {after:.2f} s after the start: it waited for git"
    assert b"suggestion:" not in raw, "a git that did not answer gave a suggestion"
    assert waiting == [True], "git was stopped when the prompt gave up on it; a cold Xcode shim would never warm"


def test_a_git_still_waiting_is_stopped_when_the_repl_ends(bin_path):
    _need_git()
    repo = _blocking_repo()
    _start(bin_path, repo)
    assert not _git_waits_at(repo), "the REPL ended and left its git running"


def test_a_git_that_answers_in_time_still_gives_the_suggestion(bin_path):
    _need_git()
    repo = _one_commit_repo()
    # The REPL's own call, once, beforehand: a cold Xcode shim (macOS) answers in time
    # only once it has run to the end.
    subprocess.run(["/usr/bin/env", "git", "log", "-1", "--name-only", "--pretty=format:"],
                   cwd=repo, env={}, capture_output=True)
    raw, _ = _start(bin_path, repo)
    assert b"suggestion: explain or improve src/recent_change.zig" in raw, \
        "the suggestion from git's answer is missing"
