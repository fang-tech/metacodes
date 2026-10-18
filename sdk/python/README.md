# metacodes for Python

Embed the [metacodes](https://github.com/metask-ai/metacodes) agent runtime in a
Python program. The package calls the AgentCore C ABI through `ctypes`: no
compiler, no third-party dependencies, Python 3.9 or newer.

```python
import metacodes

with metacodes.Runtime(tools=["Read", "Glob", "Grep"]) as runtime:
    session = runtime.session(
        "claude-sonnet-4-5",          # any model your provider serves
        provider="anthropic",         # or "openai", "gemini"
        workspace=".",
    )
    result = session.run("Summarize this repository in three lines.")
    print(result.text, result.stop_reason, result.usage)
```

The API key comes from `api_key=`, else the provider's usual variable
(`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `GEMINI_API_KEY`), else
`METACODES_API_KEY`. `base_url=` is the full endpoint; empty means the
provider's official one. An OpenAI-compatible server is addressed with
`provider="openai"` and its full URL.

## Tools written in Python

```python
@metacodes.tool(
    description="Look up an order by id.",
    input_schema={"type": "object", "properties": {"id": {"type": "string"}}, "required": ["id"]},
)
def lookup_order(arguments):
    return {"id": arguments["id"], "status": "shipped"}   # str or anything JSON-serialisable

runtime = metacodes.Runtime(tools=["Read"], host_tools=[lookup_order])
```

An exception inside a tool is returned to the model as an ordinary tool error;
the run goes on. Tools may be called from AgentCore worker threads, in parallel.

## Events and streaming

```python
for event in session.stream("Fix the failing test"):
    (tag, payload), = event.items()        # e.g. "text_chunk", "tool_start", "usage"
    if tag == "text_chunk":
        print(payload, end="", flush=True)
```

`session.run(prompt, on_event=callback)` delivers the same events to a
callback. `RunResult.text` is the final answer rebuilt from the
`output_segment_*` events (commentary and discarded output are excluded); the
event vocabulary is listed in
[doc/AGENTCORE_BINARY_ABI.md](../../doc/AGENTCORE_BINARY_ABI.md).
`session.abort()` stops the active run and `session.submit(text)` adds user
input to it; both may be called from another thread.

## Permissions

Sessions start in `permission_mode="default"` with the shell disabled. A tool
call that needs approval reaches `on_ui_request`; return an answer or `None`
(no answer means the call is not allowed):

```python
def approve(request):
    if request.kind == "permission" and request.data["tool"]["name"] == "Write":
        return request.allow_once()
    return None

session = runtime.session("…", on_ui_request=approve, allow=["Read"], deny=["Bash(rm *)"])
```

`permission_mode` is `default`, `accept_edits`, `auto`, `dont_ask` or
`full_access`; `shell` is `disabled`, `sandboxed` or `unrestricted`. `allow`,
`ask` and `deny` take rules in the `Tool(specifier)` syntax.

## Where the native library comes from

Platform wheels carry `libmetask_agentcore` and ripgrep inside the package.
Otherwise the package looks, in order, at `Runtime(library=...)`,
`METACODES_AGENTCORE_LIB`, `METACODES_AGENTCORE_SDK/lib`, and the SDK of a
metacodes install under `~/.local/opt/metacodes` (`scripts/install.sh`
installs it). `metacodes.candidate_library_paths()` prints the list. The
package refuses any library whose ABI revision differs from the one it was
written for (`metacodes.ABI_REVISION`).

## Building and testing

```sh
zig build agentcore:bundle -Dtarget=aarch64-macos -Doptimize=ReleaseSafe
python3 sdk/python/build_wheel.py --bundle zig-out/agentcore/<resolved target> --out dist/
METACODES_AGENTCORE_LIB=zig-out/agentcore/<resolved target>/lib/libmetask_agentcore.dylib \
  python3 -m unittest discover -s sdk/python/tests
```

The tests drive the real library against a scripted local mock provider; no
network, no API key. Without a library they skip, unless
`METACODES_PY_SDK_REQUIRE_LIB=1`.

## Status

Experimental, like the AgentCore ABI it wraps: the package pins one exact ABI
revision and follows it. Not yet published to PyPI; build the wheel as above.
Windows is untested. Skills, MCP, checkpoints, goals and teams exist in
the ABI but are not wrapped yet; contributions welcome.
