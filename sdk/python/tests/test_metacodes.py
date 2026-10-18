"""End-to-end tests of the Python package against the real AgentCore library.

The library comes from METACODES_AGENTCORE_LIB (or the other lookup paths in
metacodes.candidate_library_paths). Without one the suite skips, unless
METACODES_PY_SDK_REQUIRE_LIB=1, which CI sets so a missing library fails.
"""

from __future__ import annotations

import os
import sys
import tempfile
import threading
import unittest
from pathlib import Path

# METACODES_PY_SDK_TEST_INSTALLED=1 tests an installed wheel instead of src/.
if os.environ.get("METACODES_PY_SDK_TEST_INSTALLED") != "1":
    sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))
sys.path.insert(0, str(Path(__file__).resolve().parent))

import metacodes  # noqa: E402
from metacodes import _native  # noqa: E402
from mock_provider import MockProvider  # noqa: E402


def _library_available() -> bool:
    return any(path.is_file() for path in metacodes.candidate_library_paths())


REQUIRE = os.environ.get("METACODES_PY_SDK_REQUIRE_LIB") == "1"
if not _library_available() and not REQUIRE:
    raise unittest.SkipTest("AgentCore shared library not found; set METACODES_AGENTCORE_LIB")


class PythonSdkTest(unittest.TestCase):
    def setUp(self) -> None:
        self.workspace = tempfile.TemporaryDirectory()
        self.addCleanup(self.workspace.cleanup)
        self.root = Path(self.workspace.name).resolve()

    def session(self, runtime, provider, **options):
        options.setdefault("workspace", str(self.root))
        options.setdefault("api_key", "test-key")
        return runtime.session("mock-model", base_url=provider.base_url, **options)

    def test_discovery_validates_the_exact_revision(self) -> None:
        library = _native.load()
        self.assertEqual(library.api.abi_revision, metacodes.ABI_REVISION)
        self.assertEqual(library.api.struct_size, 80)

    def test_text_run_returns_final_answer_and_usage(self) -> None:
        events = []
        with MockProvider([("text", "hello from the mock")]) as provider:
            with metacodes.Runtime(tools=()) as runtime:
                session = self.session(runtime, provider)
                result = session.run("say hello", on_event=events.append)
        self.assertEqual(result.text, "hello from the mock")
        self.assertEqual(result.stop_reason, "end_turn")
        self.assertEqual(result.turns, 1)
        self.assertEqual(result.tool_calls, 0)
        self.assertEqual(result.usage["input_tokens"], 11)
        self.assertGreater(result.usage["output_tokens"], 0)
        tags = [next(iter(event)) for event in events]
        self.assertIn("text_chunk", tags)
        self.assertIn("output_segment_end", tags)
        self.assertEqual(result.segments[-1]["disposition"], "final")
        # The prompt reached the provider as the user's message.
        self.assertIn("say hello", str(provider.requests[0]["messages"]))

    def test_python_tool_result_reaches_the_model(self) -> None:
        calls = []

        @metacodes.tool(
            description="Add two integers.",
            input_schema={
                "type": "object",
                "properties": {"a": {"type": "integer"}, "b": {"type": "integer"}},
                "required": ["a", "b"],
            },
        )
        def add(arguments):
            calls.append((arguments, threading.current_thread().name))
            return str(arguments["a"] + arguments["b"])

        script = [("tool", "add", {"a": 2, "b": 3}), ("echo",)]
        with MockProvider(script) as provider:
            with metacodes.Runtime(tools=(), host_tools=[add]) as runtime:
                session = self.session(runtime, provider, permission_mode="full_access")
                result = session.run("add 2 and 3")
        self.assertEqual([call[0] for call in calls], [{"a": 2, "b": 3}])
        self.assertEqual(result.text, "saw: 5")
        self.assertEqual(result.tool_calls, 1)
        advertised = [tool["name"] for tool in provider.requests[0].get("tools", [])]
        self.assertIn("add", advertised)

    def test_python_tool_exception_is_a_model_visible_error(self) -> None:
        @metacodes.tool(description="Always fails.")
        def broken(_arguments):
            raise ValueError("disk on fire")

        script = [("tool", "broken", {}), ("echo",)]
        with MockProvider(script) as provider:
            with metacodes.Runtime(tools=(), host_tools=[broken]) as runtime:
                session = self.session(runtime, provider, permission_mode="full_access")
                result = session.run("try it")
        self.assertIn("disk on fire", result.text)
        self.assertEqual(result.stop_reason, "end_turn")

    def test_builtin_read_tool_reads_the_workspace(self) -> None:
        (self.root / "notes.txt").write_text("the secret is 42\n", encoding="utf-8")
        script = [("tool", "Read", {"file_path": "notes.txt"}), ("echo",)]
        with MockProvider(script) as provider:
            with metacodes.Runtime(tools=["Read"]) as runtime:
                session = self.session(runtime, provider)
                result = session.run("read notes.txt")
        self.assertIn("the secret is 42", result.text)

    def test_runtime_points_rg_bin_at_the_bundled_ripgrep(self) -> None:
        library = _native.load()
        if library.ripgrep is None:
            self.skipTest("this library ships no ripgrep beside it")
        saved = os.environ.pop("RG_BIN", None)
        try:
            with metacodes.Runtime(tools=["Grep"]):
                self.assertEqual(os.environ.get("RG_BIN"), str(library.ripgrep))
        finally:
            if saved is None:
                os.environ.pop("RG_BIN", None)
            else:
                os.environ["RG_BIN"] = saved

    def test_builtin_grep_finds_text_in_the_workspace(self) -> None:
        (self.root / "src.txt").write_text("alpha\nneedle-7731\nomega\n", encoding="utf-8")
        script = [("tool", "Grep", {"pattern": "needle-[0-9]+", "output_mode": "content"}), ("echo",)]
        with MockProvider(script) as provider:
            with metacodes.Runtime(tools=["Grep"]) as runtime:
                session = self.session(runtime, provider)
                result = session.run("find the needle")
        self.assertIn("needle-7731", result.text)

    def test_permission_request_reaches_the_handler_and_deny_holds(self) -> None:
        requests = []

        def on_ui_request(request):
            requests.append(request)
            return request.deny_once()

        target = self.root / "out.txt"
        script = [("tool", "Write", {"file_path": str(target), "content": "x"}), ("echo",)]
        with MockProvider(script) as provider:
            with metacodes.Runtime(tools=["Write"]) as runtime:
                session = self.session(runtime, provider, on_ui_request=on_ui_request)
                result = session.run("write a file")
        self.assertEqual(len(requests), 1)
        self.assertEqual(requests[0].kind, "permission")
        self.assertEqual(requests[0].data["tool"]["name"], "Write")
        self.assertFalse(target.exists())
        self.assertEqual(result.stop_reason, "end_turn")

    def test_permission_allow_lets_the_write_happen(self) -> None:
        target = self.root / "out.txt"
        script = [("tool", "Write", {"file_path": str(target), "content": "written"}), ("text", "done")]
        with MockProvider(script) as provider:
            with metacodes.Runtime(tools=["Write"]) as runtime:
                session = self.session(
                    runtime, provider, on_ui_request=lambda request: request.allow_once()
                )
                result = session.run("write a file")
        self.assertEqual(target.read_text(encoding="utf-8"), "written")
        self.assertEqual(result.text, "done")

    def test_no_handler_means_the_write_is_not_allowed(self) -> None:
        target = self.root / "out.txt"
        script = [("tool", "Write", {"file_path": str(target), "content": "x"}), ("text", "ok")]
        with MockProvider(script) as provider:
            with metacodes.Runtime(tools=["Write"]) as runtime:
                session = self.session(runtime, provider)
                session.run("write a file")
        self.assertFalse(target.exists())

    def test_stream_yields_events_then_result(self) -> None:
        with MockProvider([("text", "streamed")]) as provider:
            with metacodes.Runtime(tools=()) as runtime:
                session = self.session(runtime, provider)
                stream = session.stream("go")
                tags = [next(iter(event)) for event in stream]
        self.assertIn("text_chunk", tags)
        self.assertEqual(stream.result.text, "streamed")

    def test_listener_exception_is_raised_from_run_and_session_survives(self) -> None:
        def explode(_event):
            raise KeyError("listener bug")

        # The abort lands wherever the first event arrives, which may be before
        # the provider request; both script steps are the same so the second
        # Run's answer does not depend on that timing.
        with MockProvider([("text", "answer"), ("text", "answer")]) as provider:
            with metacodes.Runtime(tools=()) as runtime:
                session = self.session(runtime, provider)
                with self.assertRaises(KeyError):
                    session.run("one", on_event=explode)
                result = session.run("two")
        self.assertEqual(result.text, "answer")
        self.assertEqual(result.stop_reason, "end_turn")

    def test_shell_tool_requires_a_shell_policy(self) -> None:
        with MockProvider([]) as provider:
            with metacodes.Runtime(tools=["Bash"]) as runtime:
                with self.assertRaises(metacodes.AgentCoreError) as raised:
                    self.session(runtime, provider, tools=["Bash"], shell="disabled")
        self.assertEqual(raised.exception.status_name, "INVALID_ARGUMENT")

    def test_default_selection_drops_shell_tools_when_shell_is_disabled(self) -> None:
        with MockProvider([("text", "fine")]) as provider:
            with metacodes.Runtime(tools=["Read", "Bash"]) as runtime:
                session = self.session(runtime, provider)
                session.run("hi")
        advertised = [tool["name"] for tool in provider.requests[0].get("tools", [])]
        self.assertIn("Read", advertised)
        self.assertNotIn("Bash", advertised)

    def test_describe_reports_the_model(self) -> None:
        with MockProvider([]) as provider:
            with metacodes.Runtime(tools=()) as runtime:
                session = self.session(runtime, provider)
                description = session.describe()
                session.set_model("mock-model-2")
                self.assertIn("mock-model-2", str(session.describe()))
        self.assertIn("mock-model", str(description))

    def test_unknown_builtin_tool_is_rejected_before_loading(self) -> None:
        with self.assertRaises(ValueError):
            metacodes.Runtime(tools=["Telepathy"])

    def test_missing_library_path_is_reported(self) -> None:
        with self.assertRaises(FileNotFoundError):
            _native.load("/nonexistent/libmetask_agentcore.so")


if __name__ == "__main__":
    unittest.main()
