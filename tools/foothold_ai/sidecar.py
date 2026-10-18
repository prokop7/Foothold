#!/usr/bin/env python3
"""Foothold AI sidecar.

Bridges the DCS mission (Foothold_AI_Core.lua) and the local Claude Code CLI.
The mission writes state_<side>_<kind>.json into <Saved Games>/DCS/Missions/Saves/FootholdAI;
this script answers with orders_<side>_<kind>.lua (a data-only "return { ... }" file),
written atomically so the mission never reads a partial file.

Standard library only. Each planning cycle runs Claude Code headless:
    claude -p --model opus --mcp-config <foothold tools> --tools "" --permission-mode dontAsk ...
with the prompt on stdin, so it uses your Claude subscription login. Claude
reads the battlefield and issues orders through the game tools in mcp_server.py.

Usage:
    python sidecar.py --check          # test the Claude CLI once, no DCS needed
    python sidecar.py                  # run the bridge (Ctrl+C to stop)
    python sidecar.py --dry-run        # run the bridge without calling Claude
"""

from __future__ import annotations

import argparse
import json
import logging
import math
import os
import pathlib
import shutil
import subprocess
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import agent  # noqa: E402

STATE_SCHEMA = "footholdai.state.v1"
ORDERS_SCHEMA = "footholdai.orders.v1"
SIDES = ("red", "blue")
STATE_KINDS = ("ping", "command")
ASYNC_KINDS = {"command"}  # long Claude cycles run in the worker pool
STALE_STATE_SEC = 120      # at start-up, older command states were answered or abandoned
LINK_TEST_REUSE_SEC = 300  # one Claude link test serves both sides for this long

log = logging.getLogger("footholdai")


# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

def default_saved_games() -> pathlib.Path:
    home = pathlib.Path(os.environ.get("USERPROFILE") or pathlib.Path.home())
    for name in ("DCS", "DCS.openbeta"):
        candidate = home / "Saved Games" / name
        if candidate.exists():
            return candidate
    return home / "Saved Games" / "DCS"


# ---------------------------------------------------------------------------
# Lua literal writer (orders files)
# ---------------------------------------------------------------------------

def _lua_string(s: str) -> str:
    out = ['"']
    for ch in s:
        code = ord(ch)
        if ch == "\\":
            out.append("\\\\")
        elif ch == '"':
            out.append('\\"')
        elif ch == "\n":
            out.append("\\n")
        elif ch == "\r":
            out.append("\\r")
        elif ch == "\t":
            out.append("\\t")
        elif code < 32 or code == 127:
            out.append("\\%03d" % code)
        else:
            out.append(ch)
    out.append('"')
    return "".join(out)


def to_lua(value, indent: int = 0) -> str:
    pad = "\t" * (indent + 1)
    end = "\t" * indent
    if value is None:
        return "nil"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, int):
        return str(value)
    if isinstance(value, float):
        if math.isnan(value) or math.isinf(value):
            raise ValueError("cannot write NaN/Inf to Lua")
        return repr(value)
    if isinstance(value, str):
        return _lua_string(value)
    if isinstance(value, (list, tuple)):
        if not value:
            return "{}"
        items = ",\n".join(pad + to_lua(v, indent + 1) for v in value)
        return "{\n" + items + ",\n" + end + "}"
    if isinstance(value, dict):
        if not value:
            return "{}"
        parts = []
        for key in sorted(value, key=str):
            if isinstance(key, bool) or not isinstance(key, (str, int)):
                raise ValueError(f"unsupported Lua key: {key!r}")
            lua_key = f"[{key}]" if isinstance(key, int) else f"[{_lua_string(key)}]"
            parts.append(f"{pad}{lua_key} = {to_lua(value[key], indent + 1)}")
        return "{\n" + ",\n".join(parts) + ",\n" + end + "}"
    raise ValueError(f"unsupported value type: {type(value).__name__}")


def write_orders(exchange: pathlib.Path, side: str, orders: dict, retry_sec: float = 5.0) -> None:
    kind = orders["kind"]
    path = exchange / f"orders_{side}_{kind}.lua"
    tmp = exchange / f"orders_{side}_{kind}.lua.tmp"
    tmp.write_text("return " + to_lua(orders) + "\n", encoding="utf-8")
    # On Windows the replace fails while DCS (or a virus scanner) has a file open; retry briefly.
    deadline = time.monotonic() + retry_sec
    delay = 0.1
    while True:
        try:
            os.replace(tmp, path)
            return
        except PermissionError:
            if time.monotonic() >= deadline:
                raise
            time.sleep(delay)
            delay = min(delay * 2, 1.0)


def run_process(args: list[str], prompt: str, timeout: float, cwd: pathlib.Path) -> subprocess.CompletedProcess:
    """Run a command with stdin text; on timeout kill the whole process tree (claude.cmd starts node)."""
    kwargs = {}
    if os.name == "nt":
        kwargs["creationflags"] = subprocess.CREATE_NEW_PROCESS_GROUP
    else:
        kwargs["start_new_session"] = True
    proc = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            text=True, encoding="utf-8", errors="replace", cwd=cwd, **kwargs)
    try:
        out, err = proc.communicate(prompt, timeout=timeout)
    except subprocess.TimeoutExpired:
        kill_tree(proc)
        try:
            proc.communicate(timeout=10)
        except subprocess.TimeoutExpired:
            pass
        raise TimeoutError(f"claude did not finish within {int(timeout)} s and was stopped")
    return subprocess.CompletedProcess(args, proc.returncode, out, err)


def kill_tree(proc: subprocess.Popen) -> None:
    try:
        if os.name == "nt":
            subprocess.run(["taskkill", "/T", "/F", "/PID", str(proc.pid)], capture_output=True, timeout=15)
        else:
            os.killpg(proc.pid, 9)
    except Exception:  # already gone
        pass
    try:
        proc.kill()
    except Exception:
        pass


# ---------------------------------------------------------------------------
# Claude CLI
# ---------------------------------------------------------------------------

class ClaudeCli:
    def __init__(self, command: str, model: str, effort: str, timeout: float, workdir: pathlib.Path):
        resolved = shutil.which(command)
        if not resolved:
            raise FileNotFoundError(
                f"'{command}' not found on PATH. Install Claude Code or pass --claude <path>.")
        if resolved.lower().endswith((".cmd", ".bat")):
            log.warning("Claude resolves to a batch wrapper (%s). The native installer's claude.exe "
                        "is recommended; batch wrappers can mangle JSON arguments.", resolved)
        self.command = resolved
        self.model = model
        self.effort = effort
        self.timeout = timeout
        self.workdir = workdir

    def call(self, prompt: str, schema: dict, system_prompt_file: pathlib.Path | None = None,
             effort: str | None = None) -> dict:
        """Run one headless Claude call. Returns the validated structured output plus metadata."""
        args = [
            self.command, "-p",
            "--model", self.model,
            "--effort", effort or self.effort,
            "--output-format", "json",
            "--json-schema", json.dumps(schema, separators=(",", ":")),
            "--tools", "",
            "--no-session-persistence",
            "--strict-mcp-config",
        ]
        if system_prompt_file:
            args += ["--system-prompt-file", str(system_prompt_file)]
        started = time.monotonic()
        proc = run_process(args, prompt, self.timeout, self.workdir)
        latency_ms = int((time.monotonic() - started) * 1000)
        if proc.returncode != 0:
            raise RuntimeError(f"claude exited {proc.returncode}: {proc.stderr.strip()[:500]}")
        try:
            envelope = json.loads(proc.stdout)
        except json.JSONDecodeError as exc:
            raise RuntimeError(f"claude returned non-JSON output: {proc.stdout[:300]!r}") from exc
        if envelope.get("is_error") or envelope.get("subtype") != "success":
            raise RuntimeError(f"claude error: subtype={envelope.get('subtype')} "
                               f"result={str(envelope.get('result'))[:300]}")
        output = envelope.get("structured_output")
        if not isinstance(output, dict):
            raise RuntimeError("claude response has no structured_output")
        return {"output": output, "latency_ms": latency_ms,
                "models": sorted((envelope.get("modelUsage") or {}).keys())}


    def run_agent(self, prompt: str, system_prompt_file: pathlib.Path, mcp_config: pathlib.Path,
                  allowed_tools: list[str], effort: str, timeout: float) -> dict:
        """Run one agentic cycle with the Foothold MCP tools and no built-in tools."""
        args = [
            self.command, "-p",
            "--model", self.model,
            "--effort", effort,
            "--output-format", "json",
            "--tools", "",
            "--no-session-persistence",
            "--strict-mcp-config",
            "--mcp-config", str(mcp_config),
            "--allowedTools", ",".join(allowed_tools),
            "--permission-mode", "dontAsk",
            "--system-prompt-file", str(system_prompt_file),
        ]
        proc = run_process(args, prompt, timeout, self.workdir)
        if proc.returncode != 0:
            raise RuntimeError(f"claude exited {proc.returncode}: {proc.stderr.strip()[:500]}")
        try:
            return json.loads(proc.stdout)
        except json.JSONDecodeError as exc:
            raise RuntimeError(f"claude returned non-JSON output: {proc.stdout[:300]!r}") from exc


PING_SCHEMA = {
    "type": "object",
    "properties": {"ack": {"type": "string"}},
    "required": ["ack"],
    "additionalProperties": False,
}


def claude_link_test(claude: ClaudeCli) -> dict:
    result = claude.call("Foothold AI link test. Reply with ack set to 'link ok'.", PING_SCHEMA)
    return {"called": True, "ok": True, "ack": result["output"].get("ack"),
            "latencyMs": result["latency_ms"]}


# ---------------------------------------------------------------------------
# Bridge
# ---------------------------------------------------------------------------

class Bridge:
    def __init__(self, exchange: pathlib.Path, claude: ClaudeCli | None, cycle_effort: str = "medium",
                 cycle_timeout: float = 600.0):
        self.exchange = exchange
        self.claude = claude
        self.cycle_effort = cycle_effort
        self.cycle_timeout = cycle_timeout
        self.last_stamp: dict[tuple, tuple] = {}
        self.last_seq: dict[tuple, tuple] = {}
        self.order_seq = 0
        self.seq_lock = threading.Lock()
        self.pool = ThreadPoolExecutor(max_workers=3)  # one cycle per side, plus a link test
        self.busy: set[str] = set()
        self.started_at = time.time()
        self.link_result: dict | None = None
        self.link_result_at = 0.0
        self.link_running = False

    def next_order_seq(self) -> int:
        # Millisecond clock keeps seq increasing across sidecar restarts.
        with self.seq_lock:
            self.order_seq = max(self.order_seq + 1, int(time.time() * 1000))
            return self.order_seq

    def read_state(self, side: str, kind: str = "ping") -> dict | None:
        path = self.exchange / f"state_{side}_{kind}.json"
        key = (side, kind)
        try:
            stat = path.stat()
        except FileNotFoundError:
            return None
        stamp = (stat.st_mtime_ns, stat.st_size)
        if self.last_stamp.get(key) == stamp:
            return None
        first_sight = key not in self.last_stamp
        try:
            # errors="replace": a string the mission cut mid-character must not stall this side
            state = json.loads(path.read_bytes().decode("utf-8", errors="replace"))
        except (json.JSONDecodeError, OSError):
            return None  # mission is mid-write; retry on the next poll
        self.last_stamp[key] = stamp
        if first_sight and kind in ASYNC_KINDS and stat.st_mtime < self.started_at - STALE_STATE_SEC:
            self.last_seq[key] = (state.get("session"), state.get("seq"))
            log.info("%s: skipping %s seq=%s from before the sidecar started", side, path.name, state.get("seq"))
            return None
        if state.get("schema") != STATE_SCHEMA or state.get("side") != side or state.get("kind") != kind:
            log.warning("ignoring %s: unexpected schema/side/kind", path.name)
            return None
        seq_key = (state.get("session"), state.get("seq"))
        if self.last_seq.get(key) == seq_key:
            return None
        self.last_seq[key] = seq_key
        return state

    def handle(self, side: str, state: dict) -> None:
        kind = state.get("kind")
        handler = getattr(self, f"on_{kind}", None)
        if handler is None:
            log.warning("%s: no handler for state kind %r", side, kind)
            return
        orders = handler(side, state)
        if orders is None:
            return
        orders.update({
            "schema": ORDERS_SCHEMA,
            "side": side,
            "seq": self.next_order_seq(),
            "session": state.get("session"),
            "ackSeq": state.get("seq"),
        })
        write_orders(self.exchange, side, orders)
        log.info("%s: wrote orders kind=%s ackSeq=%s", side, orders.get("kind"), state.get("seq"))

    def on_ping(self, side: str, state: dict) -> dict:
        """Answers at once. A requested Claude link test runs in the pool; its result is
        reported with the next ping (the mission pings every minute until it sees it)."""
        claude_info = {"called": False}
        if (state.get("payload") or {}).get("wantsClaude") and self.claude:
            fresh = self.link_result and time.monotonic() - self.link_result_at < LINK_TEST_REUSE_SEC
            if fresh:
                claude_info = self.link_result
            elif not self.link_running:
                self.link_running = True
                self.pool.submit(self._link_test)
        return {"kind": "pong", "claude": claude_info}

    def _link_test(self) -> None:
        try:
            result = claude_link_test(self.claude)
            log.info("Claude link test ok in %d ms", result["latencyMs"])
        except Exception as exc:  # report the failure to the mission instead of dying
            result = {"called": True, "ok": False, "error": str(exc)[:300]}
            log.error("Claude link test failed: %s", exc)
        self.link_result, self.link_result_at = result, time.monotonic()
        self.link_running = False

    def on_command(self, side: str, state: dict) -> dict | None:
        if not self.claude:
            log.info("%s: planning request seq=%s skipped (dry run)", side, state.get("seq"))
            return None
        reason = (state.get("payload") or {}).get("reason")
        log.info("%s: planning cycle for seq=%s reason=%s - Claude is in command", side, state.get("seq"), reason)
        return agent.run_cycle(self.claude, self.exchange, side, state, self.cycle_effort, self.cycle_timeout)

    def _handle_async(self, side: str, state: dict) -> None:
        try:
            self.handle(side, state)
        except Exception:
            log.exception("%s: planning cycle seq=%s failed", side, state.get("seq"))
        finally:
            self.busy.discard(side)

    def poll_once(self) -> None:
        for side in SIDES:
            for kind in STATE_KINDS:
                if kind in ASYNC_KINDS and side in self.busy:
                    continue  # newer request is read after the running cycle finishes
                state = self.read_state(side, kind)
                if not state:
                    continue
                if kind in ASYNC_KINDS:
                    self.busy.add(side)
                    self.pool.submit(self._handle_async, side, state)
                    continue
                try:
                    self.handle(side, state)
                except Exception:
                    log.exception("%s: failed to handle %s seq=%s", side, kind, state.get("seq"))

    def run(self, poll_sec: float) -> None:
        log.info("watching %s", self.exchange)
        while True:
            self.poll_once()
            time.sleep(poll_sec)


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Foothold AI sidecar (DCS <-> Claude Code)")
    parser.add_argument("--saved-games", type=pathlib.Path, default=None,
                        help="DCS Saved Games folder (default: %%USERPROFILE%%\\Saved Games\\DCS)")
    parser.add_argument("--claude", default="claude", help="Claude Code executable (default: claude)")
    parser.add_argument("--model", default="opus", help="Claude model alias (default: opus)")
    parser.add_argument("--effort", default="medium", choices=["low", "medium", "high", "xhigh", "max"],
                        help="effort for link tests (default: medium)")
    parser.add_argument("--cycle-effort", default="medium", choices=["low", "medium", "high", "xhigh", "max"],
                        help="Claude effort for planning cycles (default: medium)")
    parser.add_argument("--cycle-timeout", type=float, default=600.0,
                        help="seconds a planning cycle may take before it is stopped (default: 600)")
    parser.add_argument("--timeout", type=float, default=300.0, help="seconds per Claude call")
    parser.add_argument("--poll", type=float, default=2.0, help="seconds between state polls")
    parser.add_argument("--dry-run", action="store_true", help="never call Claude")
    parser.add_argument("--check", action="store_true", help="run one Claude link test and exit")
    args = parser.parse_args(argv)

    saved_games = args.saved_games or default_saved_games()
    exchange = saved_games / "Missions" / "Saves" / "FootholdAI"
    exchange.mkdir(parents=True, exist_ok=True)

    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
        handlers=[logging.StreamHandler(sys.stdout),
                  logging.FileHandler(exchange / "sidecar.log", encoding="utf-8")],
    )

    claude = None
    if not args.dry_run:
        claude = ClaudeCli(args.claude, args.model, args.effort, args.timeout, exchange)
        log.info("using %s (model=%s effort=%s)", claude.command, args.model, args.effort)

    if args.check:
        if not claude:
            log.error("--check needs Claude; remove --dry-run")
            return 2
        info = claude_link_test(claude)
        log.info("Claude link test ok: ack=%r latency=%d ms", info["ack"], info["latencyMs"])
        return 0

    try:
        Bridge(exchange, claude, args.cycle_effort, args.cycle_timeout).run(args.poll)
    except KeyboardInterrupt:
        log.info("stopped")
    return 0


if __name__ == "__main__":
    sys.exit(main())
