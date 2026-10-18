"""Zero-provider preflight of the WorkBuddy leaderboard protocol.

Runs the leaderboard job shape (leaderboard_jobs.preflight_job_document) on one
synthetic task through the official WorkBuddy/Harbor runner, the job-private
proxy and real Linux metacodes/TinyKG/Lean binaries, against the loopback
scripted provider's ``leaderboard-protocol-v1`` scenario.  The scenario refuses
any request whose upstream body carries a sampling override, lacks adaptive
thinking with effort high, deviates from the 32768-token output budget, shows
a protocol-disabled tool, or did not receive the instruction; this runner then
audits the proxy's per-trial record of the same bodies, the gapless request
sequence, the runtime contract, the compaction thresholds metacodes derived
from the declared window, and the verifier result.

It reads no provider credential and makes no external request.  The receipt is
infrastructure evidence (``quality_evidence=false``), never a benchmark score.
The Web/Office judge route is not exercised here.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Any, Dict, Iterable, List, Mapping, Sequence

from . import WORKBUDDY_PINNED_COMMIT
from . import leaderboard_jobs
from .install_overlay import install
from .mock_provider import (
    LEADERBOARD_ANCHOR_INPUT_TOKENS,
    LEADERBOARD_DISABLED_TOOLS,
    LEADERBOARD_MAX_TOKENS,
    MOCK_CREDENTIAL,
    READY_DEADLINE_S,
)
from .run_w05 import (
    W05Error,
    _clean_environment,
    _fresh_checkout,
    _identity,
    _json,
    _json_lines,
    _private_new,
    _run,
    _stable_evidence,
    _terminate_process,
    _write_all,
    _wire_json_sha256,
)
from .stage_artifacts import stage
from .trace import TraceError

SCHEMA_VERSION = "metacodes-workbuddy-lb-preflight-receipt-v1"
SCENARIO = "leaderboard-protocol-v1"
JOB_SLUG = leaderboard_jobs.PREFLIGHT_SLUG
TASK_NAME = leaderboard_jobs.PREFLIGHT_TASK
EXPECTED_PROVIDER_REQUESTS = 2
# metacodes' rule (core/context_pressure.zig): the window minus the full output
# reserve, minus a 13K buffer for auto-compaction and 20K for the warning.
EXPECTED_AUTO_COMPACT = leaderboard_jobs.CONTEXT_WINDOW - LEADERBOARD_MAX_TOKENS - 13_000
EXPECTED_WARNING = leaderboard_jobs.CONTEXT_WINDOW - LEADERBOARD_MAX_TOKENS - 20_000
SAMPLING_OVERRIDES = ("temperature", "top_p", "top_k")


class PreflightError(W05Error):
    pass


def _single_new_trial(workbuddy: Path, started_ns: int) -> tuple[Path, Path]:
    root = workbuddy / "results" / JOB_SLUG
    trajectories = [
        path
        for path in root.rglob("trajectory.json")
        if path.is_file() and path.stat().st_mtime_ns >= started_ns
    ] if root.exists() else []
    if len(trajectories) != 1:
        raise PreflightError(f"expected one new preflight trajectory, found {trajectories}")
    trajectory = trajectories[0]
    if not trajectory.parent.parent.name.startswith(f"{TASK_NAME}__"):
        raise PreflightError(f"preflight produced another task identity: {trajectory}")
    return trajectory.parent, trajectory.parent.parent


def upstream_body_assertions(body: Mapping[str, Any]) -> None:
    """The protocol as the provider received it (after the proxy's injection)."""
    present = [key for key in SAMPLING_OVERRIDES if key in body]
    if present:
        raise PreflightError(f"upstream body carries sampling overrides: {present}")
    if body.get("thinking") != {"type": "adaptive"}:
        raise PreflightError("upstream body is not in think mode")
    if body.get("output_config") != {"effort": "high"}:
        raise PreflightError("upstream body does not fix reasoning effort high")
    if body.get("max_tokens") != LEADERBOARD_MAX_TOKENS:
        raise PreflightError("upstream output budget drifted")
    tools = {
        str(tool.get("name"))
        for tool in body.get("tools") or []
        if isinstance(tool, Mapping)
    }
    visible = sorted(set(LEADERBOARD_DISABLED_TOOLS) & tools)
    if visible:
        raise PreflightError(f"protocol-disabled tools are provider-visible: {visible}")
    if "WebFetch" not in tools:
        raise PreflightError("WebFetch, enabled in both official harnesses, is missing")


def proxy_audit(
    rows: Iterable[Mapping[str, Any]], mock_rows: Sequence[Mapping[str, Any]]
) -> List[Mapping[str, Any]]:
    records = list(rows)
    if len(records) != EXPECTED_PROVIDER_REQUESTS or len(mock_rows) != len(records):
        raise PreflightError("proxy request count differs from the scripted provider")
    if [record.get("seq") for record in records] != list(
        range(1, EXPECTED_PROVIDER_REQUESTS + 1)
    ):
        raise PreflightError("proxy request sequence is not a gapless 1..N wave")
    suffix = f"--{leaderboard_jobs.PREFLIGHT_MODEL}"
    bodies = []
    for record, mock_row in zip(records, mock_rows):
        request = record.get("request")
        upstream = request.get("upstream_body") if isinstance(request, Mapping) else None
        upstream_url = request.get("upstream_url") if isinstance(request, Mapping) else None
        if (
            not str(record.get("route") or "").endswith(suffix)
            or not str(record.get("trial_id") or "").startswith(f"{TASK_NAME}__")
            or not isinstance(upstream, Mapping)
            or not isinstance(upstream_url, str)
            or not upstream_url.startswith("http://127.0.0.1:")
            or not upstream_url.endswith("/v1/messages")
            or _wire_json_sha256(upstream) != mock_row.get("body_sha256")
        ):
            raise PreflightError("proxy record does not match the scripted provider")
        upstream_body_assertions(upstream)
        bodies.append(upstream)
    return bodies


def mock_audit(rows: Iterable[Mapping[str, Any]]) -> List[Mapping[str, Any]]:
    records = list(rows)
    if len(records) != EXPECTED_PROVIDER_REQUESTS:
        raise PreflightError(
            f"expected {EXPECTED_PROVIDER_REQUESTS} scripted requests, found {len(records)}"
        )
    for number, row in enumerate(records, 1):
        if (
            row.get("schema_version") != "metacodes-workbuddy-mock-provider-v2"
            or row.get("scenario") != SCENARIO
            or row.get("request_number") != number
        ):
            raise PreflightError("scripted-provider request audit drifted")
    return records


def runtime_contract_assertions(
    contract: Mapping[str, Any], instruction_copies: Mapping[str, bytes]
) -> None:
    if len(instruction_copies) != 1:
        raise PreflightError("expected one recorded instruction copy")
    ((name, payload),) = instruction_copies.items()
    digest = hashlib.sha256(payload).hexdigest()
    if (
        contract.get("instruction_delivery") != "stdin-uploaded-file"
        or contract.get("instruction_sha256") != digest
        or name != f"metacodes-instruction-{digest[:16]}.md"
        or contract.get("reasoning_effort") != leaderboard_jobs.REASONING_EFFORT
        or contract.get("declared_context_window") != leaderboard_jobs.CONTEXT_WINDOW
        or contract.get("transport_model_is_route") is not True
        or contract.get("quality_evidence") is not False
        or contract.get("fresh_home") is not True
        or (contract.get("project_control") or {}).get("mode") != "absent"
    ):
        raise PreflightError("runtime contract does not carry the leaderboard protocol")


def output_assertions(events: Sequence[Mapping[str, Any]]) -> Mapping[str, Any]:
    warnings = [event for event in events if event.get("type") == "context_warning"]
    results = [event for event in events if event.get("type") == "result"]
    if len(results) != 1 or results[0].get("stop_reason") != "end_turn":
        raise PreflightError("metacodes did not end the preflight run normally")
    current = warnings[0].get("current_tokens") if len(warnings) == 1 else None
    if (
        len(warnings) != 1
        or warnings[0].get("auto_compact_threshold") != EXPECTED_AUTO_COMPACT
        or isinstance(current, bool)
        or not isinstance(current, int)
        or not EXPECTED_WARNING <= current < EXPECTED_AUTO_COMPACT
    ):
        raise PreflightError(
            "metacodes did not derive its compaction thresholds from the 200K window"
        )
    return warnings[0]


def run_lb_preflight(
    *,
    workbuddy: Path,
    metacodes: Path,
    tinykg: Path,
    formal_kernel: Path,
    ripgrep: Path,
    metacodes_commit: str,
    tinykg_commit: str,
    metacodes_license: Path,
    tinykg_license: Path,
    lean_license: Path,
    bash: Path,
    uv: Path,
    metacodes_license_spdx: str = "MIT",
) -> Dict[str, object]:
    workbuddy = workbuddy.resolve(strict=True)
    _fresh_checkout(workbuddy)
    overlay = install(workbuddy)
    job_path = workbuddy / "configs/jobs" / f"{JOB_SLUG}.yaml"
    if job_path.read_text(encoding="utf-8") != leaderboard_jobs.dump(
        leaderboard_jobs.preflight_job_document()
    ):
        raise PreflightError("installed preflight job differs from the protocol")
    artifact_dir = workbuddy / "configs/harnesses/metacodes/docker/artifacts"
    if artifact_dir.exists():
        raise PreflightError("split-mount stage already exists after overlay install")
    stage(
        output=artifact_dir,
        metacodes=metacodes,
        tinykg=tinykg,
        formal_kernel=formal_kernel,
        ripgrep=ripgrep.resolve(),
        metacodes_commit=metacodes_commit,
        tinykg_commit=tinykg_commit,
        licenses=(
            ("metacodes", metacodes_license_spdx, metacodes_license),
            ("tinykg", "Apache-2.0", tinykg_license),
            ("lean4", "Apache-2.0", lean_license),
        ),
    )

    with tempfile.TemporaryDirectory(prefix="metacodes-workbuddy-lb-") as directory:
        private = Path(directory)
        os.chmod(private, 0o700)
        ready = private / "mock-ready.json"
        mock_requests = private / "mock-requests.jsonl"
        process = subprocess.Popen(
            [
                sys.executable,
                "-m",
                "scripts.eval.workbuddy.mock_provider",
                "--ready",
                str(ready),
                "--request-log",
                str(mock_requests),
                "--scenario",
                SCENARIO,
            ],
            cwd=Path(__file__).resolve().parents[3],
            env=_clean_environment(os.environ),
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
        )
        try:
            deadline = time.monotonic() + READY_DEADLINE_S
            while not ready.exists() and time.monotonic() < deadline:
                if process.poll() is not None:
                    raise PreflightError(f"mock provider exited early: {process.stderr.read()}")
                time.sleep(0.02)
            if not ready.is_file():
                raise PreflightError("mock provider did not become ready")
            ready_value = _json(ready)
            port = ready_value.get("port")
            if ready_value.get("scenario") != SCENARIO or isinstance(port, bool) or not isinstance(port, int):
                raise PreflightError("mock provider started another scenario or no port")

            environment = _clean_environment(os.environ)
            environment.update(
                {
                    "METACODES_LB_MOCK_BASE_URL": f"http://127.0.0.1:{port}/v1/messages",
                    "WBBENCH_PROXY_MAX_RETRIES": "0",
                    "WBBENCH_PROXY_RETRY_DELAY_MS": "1",
                    "SHARDS": "1",
                    "SHARD_CONCURRENCY": "1",
                    "PROXY_MAX_CONCURRENT": "1",
                    "SHARED_PROXY": "0",
                    "AUTO_BUILD_HARNESS_MOUNT": "0",
                    "DOCKER_DEFAULT_PLATFORM": "linux/amd64",
                }
            )
            _run(
                [str(uv), "run", "--frozen", str(bash), "scripts/harness/build-harness-mounts.sh",
                 "--harness", "metacodes/0.1.0"],
                cwd=workbuddy,
                env=environment,
            )
            started_ns = time.time_ns()
            credential_read, credential_write = os.pipe()
            try:
                _write_all(credential_write, MOCK_CREDENTIAL.encode("utf-8"))
            finally:
                os.close(credential_write)
            environment["METACODES_WORKBUDDY_PROVIDER_KEY_FD_REF"] = f"fd://{credential_read}"
            try:
                _run(
                    [str(uv), "run", "--frozen", str(bash), "scripts/run.sh", "--job", JOB_SLUG],
                    cwd=workbuddy,
                    env=environment,
                    pass_fds=(credential_read,),
                )
            finally:
                os.close(credential_read)
            if process.poll() is not None:
                raise PreflightError(
                    f"mock provider exited before evidence freeze: {process.stderr.read()}"
                )
            _terminate_process(process)

            agent_dir, trial_dir = _single_new_trial(workbuddy, started_ns)
            mock_rows = mock_audit(_json_lines(mock_requests))
            retained_mock_requests = workbuddy / ".workspace/metacodes-lb-mock-requests.jsonl"
            retained_mock_requests.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            os.chmod(retained_mock_requests.parent, 0o700)
            _private_new(retained_mock_requests, mock_requests.read_bytes())
            proxy_request_path = agent_dir / "requests.jsonl"
            bodies = proxy_audit(_json_lines(proxy_request_path), mock_rows)
            contract_path = agent_dir / "metacodes-runtime-contract.json"
            instruction_paths = sorted(agent_dir.glob("metacodes-instruction-*.md"))
            runtime_contract_assertions(
                _json(contract_path),
                {path.name: path.read_bytes() for path in instruction_paths},
            )
            output_path = agent_dir / "metacodes-output.jsonl"
            warning = output_assertions(_json_lines(output_path))
            reward = trial_dir / "verifier/reward.txt"
            if not reward.is_file() or reward.read_text(encoding="utf-8").strip() != "1":
                raise PreflightError("preflight verifier did not award 1")

            evidence_paths = {
                "proxy_requests": proxy_request_path,
                "mock_requests": retained_mock_requests,
                "runtime_contract": contract_path,
                "instruction": instruction_paths[0],
                "metacodes_output": output_path,
                "trajectory": agent_dir / "trajectory.json",
                "verifier_reward": reward,
            }
            evidence_before = {name: _identity(path) for name, path in evidence_paths.items()}
            receipt = {
                "schema_version": SCHEMA_VERSION,
                "quality_evidence": False,
                "network": {
                    "external_paid_provider_requests": 0,
                    "mock_scripted_provider_requests": EXPECTED_PROVIDER_REQUESTS,
                    "provider": f"loopback-scripted-{SCENARIO}",
                },
                "workbuddy_commit": WORKBUDDY_PINNED_COMMIT,
                "overlay_sha256": overlay["overlay_sha256"],
                "split_mount_manifest": _identity(
                    artifact_dir / "share/metacodes/artifact-manifest.json"
                ),
                "protocol": {
                    "upstream_body_keys": sorted(
                        key for key in bodies[0] if key not in ("messages", "system", "tools")
                    ),
                    "thinking": bodies[0]["thinking"],
                    "output_config": bodies[0]["output_config"],
                    "max_tokens": bodies[0]["max_tokens"],
                    "provider_visible_tools": sorted(
                        str(tool.get("name")) for tool in bodies[0].get("tools") or []
                    ),
                    "context_warning": {
                        key: warning[key]
                        for key in ("current_tokens", "auto_compact_threshold")
                    },
                    "anchored_input_tokens": LEADERBOARD_ANCHOR_INPUT_TOKENS,
                },
                "artifacts": evidence_before,
                "verifier_reward": 1,
            }
            _stable_evidence(evidence_before, evidence_paths)
            receipt_path = workbuddy / ".workspace/metacodes-lb-preflight-receipt.json"
            _private_new(
                receipt_path,
                (json.dumps(receipt, sort_keys=True, indent=2) + "\n").encode("utf-8"),
            )
            return receipt
        finally:
            _terminate_process(process)
            if process.stderr is not None:
                process.stderr.close()


def main(argv: List[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("workbuddy_checkout", type=Path)
    parser.add_argument("--metacodes", type=Path, required=True)
    parser.add_argument("--tinykg", type=Path, required=True)
    parser.add_argument("--formal-kernel", type=Path, required=True)
    parser.add_argument("--ripgrep", type=Path, required=True)
    parser.add_argument("--metacodes-commit", required=True)
    parser.add_argument("--tinykg-commit", required=True)
    parser.add_argument("--metacodes-license", type=Path, required=True)
    parser.add_argument("--metacodes-license-spdx", default="MIT")
    parser.add_argument("--tinykg-license", type=Path, required=True)
    parser.add_argument("--lean-license", type=Path, required=True)
    parser.add_argument("--bash", type=Path, default=Path(shutil.which("bash") or "bash"))
    parser.add_argument("--uv", type=Path, default=Path(shutil.which("uv") or "uv"))
    args = parser.parse_args(argv)
    try:
        receipt = run_lb_preflight(
            workbuddy=args.workbuddy_checkout,
            metacodes=args.metacodes,
            tinykg=args.tinykg,
            formal_kernel=args.formal_kernel,
            ripgrep=args.ripgrep,
            metacodes_commit=args.metacodes_commit,
            tinykg_commit=args.tinykg_commit,
            metacodes_license=args.metacodes_license,
            tinykg_license=args.tinykg_license,
            lean_license=args.lean_license,
            metacodes_license_spdx=args.metacodes_license_spdx,
            bash=args.bash,
            uv=args.uv,
        )
    except (OSError, TraceError, ValueError, W05Error) as exc:
        parser.error(str(exc))
    print(json.dumps(receipt, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
