"""Commander requests: schema, prompt and campaign memory for the sidecar.

The JSON schema is built per request: zone fields are enums of the zone names
in that state, so Claude cannot return a zone that does not exist. The mission
validates everything again before using it.
"""

from __future__ import annotations

import json
import pathlib
import random
import re
import time

PROMPTS = pathlib.Path(__file__).resolve().parent / "prompts"

PERSONALITIES = {
    "red": {
        "aggressive": "High tempo. Keeps pressure on several zones, accepts losses, punishes BLUE gaps fast.",
        "cautious": "Defends and attrits. Strengthens the front and air defences, strikes only good opportunities.",
        "deceptive": "Feints and shifting axes. Avoids repeating targets, sets up surprise on a second front.",
        "logistician": "Builds economy and depots first, then commits to one heavy, well-supplied push.",
        "opportunist": "Hunts weakly defended or neglected zones and exploits BLUE's recent losses.",
    },
    "blue": {
        "supportive": "Follows the players. Clears threats in their way and covers the areas they fight in.",
        "methodical": "Rolls back air defences first, then airfields, then the front, one sector at a time.",
        "aggressive": "Pushes AI missions deep to keep RED off balance while players hold the front.",
    },
}

MAX_HISTORY = 12


def campaign_key(state: dict) -> str:
    campaign = (state.get("payload") or {}).get("campaign") or {}
    raw = f"{campaign.get('theatre') or state.get('theatre') or 'unknown'}_{campaign.get('saveFile') or 'default'}"
    return re.sub(r"[^A-Za-z0-9_.-]+", "_", raw)[:120]


class Memory:
    """Per-campaign memory: personality per side and recent plan history."""

    def __init__(self, exchange: pathlib.Path, key: str):
        self.path = exchange / f"memory_{key}.json"
        try:
            self.data = json.loads(self.path.read_text(encoding="utf-8"))
        except (FileNotFoundError, json.JSONDecodeError):
            self.data = {"personality": {}, "history": {"red": [], "blue": []}}

    def personality(self, side: str) -> str:
        chosen = self.data["personality"].get(side)
        if chosen not in PERSONALITIES[side]:
            chosen = random.choice(sorted(PERSONALITIES[side]))
            self.data["personality"][side] = chosen
            self.save()
        return chosen

    def history(self, side: str) -> list:
        return self.data["history"].setdefault(side, [])

    def record(self, side: str, entry: dict) -> None:
        history = self.history(side)
        history.insert(0, entry)
        del history[MAX_HISTORY:]
        self.save()

    def save(self) -> None:
        tmp = self.path.with_suffix(".tmp")
        tmp.write_text(json.dumps(self.data, indent=1), encoding="utf-8")
        tmp.replace(self.path)


def _zone_names(payload: dict, predicate) -> list[str]:
    return sorted({z["name"] for z in payload.get("zones", []) if predicate(z)})


def build_schema(side: str, payload: dict) -> dict:
    enemy = _zone_names(payload, lambda z: z.get("side") != side and not z.get("suspended"))
    own = _zone_names(payload, lambda z: z.get("side") == side and not z.get("suspended"))
    enemy_enum = {"type": "string", "enum": enemy} if enemy else {"type": "string"}
    own_enum = {"type": "string", "enum": own} if own else {"type": "string"}
    props = {
        "name": {"type": "string"},
        "weight": {"type": "number"},
        "rationale": {"type": "string"},
        "focusZones": {"type": "array", "items": {
            "type": "object",
            "properties": {"zone": enemy_enum, "weight": {"type": "number"}},
            "required": ["zone", "weight"],
            "additionalProperties": False,
        }},
        "avoidZones": {"type": "array", "items": enemy_enum},
        "capZones": {"type": "array", "items": own_enum},
    }
    if side == "red":
        menu = payload.get("menu") or {}
        props["strategy"] = {"type": "string", "enum": list(menu.get("strategies", [])) + ["keep"]}
        props["strategyGoal"] = {"type": "string", "enum": enemy + [""]} if enemy else {"type": "string"}
        props["reinforceZones"] = {"type": "array", "items": own_enum}
        for field, names in (("doctrineWeights", menu.get("doctrines", [])),
                             ("budgetWeights", menu.get("budgetActions", []))):
            props[field] = {
                "type": "object",
                "properties": {n: {"type": "number"} for n in names},
                "required": list(names),
                "additionalProperties": False,
            }
    return {
        "type": "object",
        "properties": {
            "summary": {"type": "string"},
            "plans": {"type": "array", "items": {
                "type": "object",
                "properties": props,
                "required": list(props),
                "additionalProperties": False,
            }},
        },
        "required": ["summary", "plans"],
        "additionalProperties": False,
    }


def build_prompt(side: str, payload: dict, personality: str, history: list) -> str:
    recent = [{k: h.get(k) for k in ("missionClockMin", "reason", "summary", "plans")} for h in history[:5]]
    return "\n".join([
        f"Side: {side.upper()}. Request reason: {payload.get('reason')}.",
        f"Personality: {personality} - {PERSONALITIES[side][personality]}",
        "",
        "Your previous plans this campaign (newest first; the mission picked one at random each time):",
        "```json", json.dumps(recent, indent=1), "```",
        "",
        "Current state:",
        "```json", json.dumps(payload, indent=1), "```",
        "",
        "Return 2 or 3 distinct plans with relative weights, and a short summary of your intent.",
    ])


def sanitize(side: str, output: dict) -> dict:
    """Light clean-up before the plans go to Lua (which validates again)."""
    plans = []
    for plan in (output.get("plans") or [])[:3]:
        if not isinstance(plan, dict):
            continue
        clean = dict(plan)
        clean["name"] = str(clean.get("name", "plan"))[:60]
        clean["rationale"] = str(clean.get("rationale", ""))[:400]
        try:
            clean["weight"] = max(0.05, min(10.0, float(clean.get("weight", 1))))
        except (TypeError, ValueError):
            clean["weight"] = 1.0
        clean["focusZones"] = [z for z in clean.get("focusZones") or [] if isinstance(z, dict)][:5]
        if side == "red" and clean.get("strategy") == "keep":
            clean.pop("strategy", None)
            clean.pop("strategyGoal", None)
        plans.append(clean)
    return {"summary": str(output.get("summary", ""))[:300], "plans": plans}


def handle(claude, exchange: pathlib.Path, side: str, state: dict, effort: str | None = None) -> dict:
    payload = state.get("payload") or {}
    memory = Memory(exchange, campaign_key(state))
    personality = memory.personality(side)
    prompt = build_prompt(side, payload, personality, memory.history(side))
    schema = build_schema(side, payload)
    result = claude.call(prompt, schema, PROMPTS / f"commander_{side}.md", effort=effort)
    orders = sanitize(side, result["output"])
    memory.record(side, {
        "time": int(time.time()),
        "missionClockMin": payload.get("missionClockMin"),
        "reason": payload.get("reason"),
        "summary": orders["summary"],
        "plans": [{"name": p["name"], "weight": p["weight"],
                   "focus": [z.get("zone") for z in p.get("focusZones", [])]} for p in orders["plans"]],
    })
    with open(exchange / f"commander_{side}.log", "a", encoding="utf-8") as f:
        f.write(json.dumps({"time": int(time.time()), "personality": personality,
                            "latencyMs": result["latency_ms"], **orders}) + "\n")
    orders["kind"] = "commander"
    orders["personality"] = personality
    return orders
