#!/usr/bin/env python3
"""Foothold AI sidecar.

Bridges the DCS mission (Foothold_AI_Core.lua) and the local Claude Code CLI.
The mission writes state_<side>.json into <Saved Games>/DCS/Missions/Saves/FootholdAI;
this script answers with orders_<side>.lua (a data-only "return { ... }" file),
written atomically so the mission never reads a partial file.

Standard library only. Claude is called as:
    claude -p --model opus --output-format json --json-schema <schema> --tools "" ...
with the prompt on stdin, so it uses your Claude subscription login.

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
import time

STATE_SCHEMA = "footholdai.state.v1"
ORDERS_SCHEMA = "footholdai.orders.v1"
SIDES = ("red", "blue")

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


def write_orders(exchange: pathlib.Path, side: str, orders: dict) -> None:
    path = exchange / f"orders_{side}.lua"
    tmp = exchange / f"orders_{side}.lua.tmp"
    tmp.write_text("return " + to_lua(orders) + "\n", encoding="utf-8")
    os.replace(tmp, path)


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

    def call(self, prompt: str, schema: dict, system_prompt_file: pathlib.Path | None = None) -> dict:
        """Run one headless Claude call. Returns the validated structured output plus metadata."""
        args = [
            self.command, "-p",
            "--model", self.model,
            "--effort", self.effort,
            "--output-format", "json",
            "--json-schema", json.dumps(schema, separators=(",", ":")),
            "--tools", "",
            "--no-session-persistence",
            "--strict-mcp-config",
        ]
        if system_prompt_file:
            args += ["--system-prompt-file", str(system_prompt_file)]
        started = time.monotonic()
        proc = subprocess.run(
            args, input=prompt, capture_output=True, text=True, encoding="utf-8",
            timeout=self.timeout, cwd=self.workdir,
        )
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
    def __init__(self, exchange: pathlib.Path, claude: ClaudeCli | None):
        self.exchange = exchange
        self.claude = claude
        self.last_stamp: dict[str, tuple] = {}
        self.last_seq: dict[str, tuple] = {}
        self.order_seq = 0

    def next_order_seq(self) -> int:
        # Millisecond clock keeps seq increasing across sidecar restarts.
        self.order_seq = max(self.order_seq + 1, int(time.time() * 1000))
        return self.order_seq

    def read_state(self, side: str) -> dict | None:
        path = self.exchange / f"state_{side}.json"
        try:
            stat = path.stat()
        except FileNotFoundError:
            return None
        stamp = (stat.st_mtime_ns, stat.st_size)
        if self.last_stamp.get(side) == stamp:
            return None
        try:
            state = json.loads(path.read_text(encoding="utf-8"))
        except (json.JSONDecodeError, UnicodeDecodeError, OSError):
            return None  # mission is mid-write; retry on the next poll
        self.last_stamp[side] = stamp
        if state.get("schema") != STATE_SCHEMA or state.get("side") != side:
            log.warning("ignoring %s: unexpected schema/side", path.name)
            return None
        key = (state.get("session"), state.get("seq"))
        if self.last_seq.get(side) == key:
            return None
        self.last_seq[side] = key
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
        claude_info = {"called": False}
        if (state.get("payload") or {}).get("wantsClaude") and self.claude:
            try:
                claude_info = claude_link_test(self.claude)
                log.info("%s: Claude link test ok in %d ms", side, claude_info["latencyMs"])
            except Exception as exc:  # report the failure to the mission instead of dying
                claude_info = {"called": True, "ok": False, "error": str(exc)[:300]}
                log.error("%s: Claude link test failed: %s", side, exc)
        return {"kind": "pong", "claude": claude_info}

    def run(self, poll_sec: float) -> None:
        log.info("watching %s", self.exchange)
        while True:
            for side in SIDES:
                state = self.read_state(side)
                if state:
                    try:
                        self.handle(side, state)
                    except Exception:
                        log.exception("%s: failed to handle state seq=%s", side, state.get("seq"))
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
    parser.add_argument("--effort", default="medium", choices=["low", "medium", "high", "xhigh", "max"])
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
        Bridge(exchange, claude).run(args.poll)
    except KeyboardInterrupt:
        log.info("stopped")
    return 0


if __name__ == "__main__":
    sys.exit(main())
