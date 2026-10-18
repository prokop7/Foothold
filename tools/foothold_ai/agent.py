"""One Claude planning cycle per side: Claude Code runs headless with the
Foothold game tools (mcp_server.py) and issues orders for the mission."""

from __future__ import annotations

import json
import logging
import pathlib
import random
import re
import sys
import time

import mcp_server

HERE = pathlib.Path(__file__).resolve().parent
PROMPTS = HERE / "prompts"
log = logging.getLogger("footholdai")

PERSONALITIES = {
    "red": {
        "aggressive": "High tempo. Keeps pressure on several zones, accepts losses, punishes BLUE gaps fast.",
        "cautious": "Defends and attrits. Strengthens the front and air defences, strikes only good opportunities.",
        "deceptive": "Feints and shifting axes. Avoids repeating targets, sets up surprise on a second front.",
        "logistician": "Builds supply and depots first, then commits to one heavy, well-supplied push.",
        "opportunist": "Hunts weakly defended or neglected zones and exploits BLUE's recent losses.",
    },
    "blue": {
        "supportive": "Follows the players. Clears threats in their way and covers the areas they fight in.",
        "methodical": "Rolls back air defences first, then airfields, then the front, one sector at a time.",
        "aggressive": "Pushes AI missions deep to keep RED off balance while players hold the front.",
    },
}
MAX_HISTORY = 20


def campaign_key(state: dict) -> str:
    c = (state.get("payload") or {}).get("campaign") or {}
    raw = f"{c.get('theatre') or state.get('theatre') or 'unknown'}_{c.get('saveFile') or 'default'}"
    return re.sub(r"[^A-Za-z0-9_.-]+", "_", raw)[:120]


def load_memory(path: pathlib.Path, side: str) -> dict:
    try:
        memory = json.loads(path.read_text(encoding="utf-8"))
    except (FileNotFoundError, json.JSONDecodeError):
        memory = {}
    if memory.get("personality") not in PERSONALITIES[side]:
        memory["personality"] = random.choice(sorted(PERSONALITIES[side]))
    memory.setdefault("history", [])
    memory.setdefault("cycles", 0)
    return memory


def save_json(path: pathlib.Path, data) -> None:
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(data, indent=1), encoding="utf-8")
    tmp.replace(path)


def build_prompt(side: str, payload: dict, memory: dict) -> str:
    personality = memory["personality"]
    return "\n".join([
        f"Planning cycle {memory['cycles']} for {side.upper()}.",
        f"Why now: {payload.get('reason')}. Mission clock: {payload.get('missionClockMin')} min.",
        f"Your personality: {personality} - {PERSONALITIES[side][personality]}",
        "",
        "Start with get_overview, look at what you need, issue your orders, keep your standing orders "
        "current, then call finish_cycle with a summary and notes for your next cycle.",
    ])


def run_cycle(claude, exchange: pathlib.Path, side: str, state: dict, effort: str, timeout: float) -> dict:
    payload = state.get("payload") or {}
    key = campaign_key(state)
    cycle_dir = exchange / "cycles"
    cycle_dir.mkdir(exist_ok=True)
    memory_path = exchange / f"memory_{key}_{side}.json"
    memory = load_memory(memory_path, side)
    memory["cycles"] += 1
    save_json(memory_path, memory)

    state_path = cycle_dir / f"{side}_state.json"
    out_path = cycle_dir / f"{side}_orders.json"
    mcp_path = cycle_dir / f"{side}_mcp.json"
    save_json(state_path, state)
    if out_path.exists():
        out_path.unlink()
    mcp_config = {"mcpServers": {"foothold": {
        "command": sys.executable,
        "args": [str(HERE / "mcp_server.py"), "--state", str(state_path),
                 "--out", str(out_path), "--memory", str(memory_path)],
    }}}
    save_json(mcp_path, mcp_config)
    allowed = [f"mcp__foothold__{t['name']}" for t in mcp_server.tool_specs(side)]

    started = time.monotonic()
    error = None
    try:
        envelope = claude.run_agent(build_prompt(side, payload, memory), PROMPTS / f"command_{side}.md",
                                    mcp_path, allowed, effort, timeout)
        if envelope.get("is_error"):
            error = f"claude error: {envelope.get('subtype')} {str(envelope.get('result'))[:200]}"
    except Exception as exc:  # timeouts and CLI failures: keep the orders already queued
        error = str(exc)[:300]
    elapsed = round(time.monotonic() - started)

    try:
        result = json.loads(out_path.read_text(encoding="utf-8"))
    except (FileNotFoundError, json.JSONDecodeError):
        result = {"orders": [], "summary": "", "notes": "", "finished": False}
    prefix = f"{side[0]}{memory['cycles']}-"
    orders = []
    for order in result.get("orders", []):
        order = dict(order)
        order["id"] = prefix + str(order.get("id", len(orders) + 1))
        orders.append(order)

    memory = load_memory(memory_path, side)  # the MCP server only reads it; reload to stay current
    if result.get("notes"):
        memory["notes"] = result["notes"]
    memory["history"].insert(0, {
        "cycle": memory["cycles"], "missionClockMin": payload.get("missionClockMin"),
        "reason": payload.get("reason"), "summary": result.get("summary", ""),
        "orders": len(orders), "finished": result.get("finished", False), "error": error,
    })
    del memory["history"][MAX_HISTORY:]
    save_json(memory_path, memory)
    with open(exchange / f"command_{side}.log", "a", encoding="utf-8") as f:
        f.write(json.dumps({"time": int(time.time()), "cycle": memory["cycles"], "seconds": elapsed,
                            "personality": memory["personality"], "error": error,
                            "summary": result.get("summary", ""), "orders": orders}) + "\n")
    if error:
        log.warning("%s: cycle %d ended with error after %d s: %s (%d orders kept)",
                    side, memory["cycles"], elapsed, error, len(orders))
    else:
        log.info("%s: cycle %d done in %d s, %d orders, %d tool calls: %s", side, memory["cycles"], elapsed,
                 len(orders), result.get("toolCalls", 0), result.get("summary", "")[:200])
    return {"kind": "command", "cycle": memory["cycles"], "orders": orders,
            "summary": result.get("summary", "")}
