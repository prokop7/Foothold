#!/usr/bin/env python3
"""Foothold game tools for Claude (MCP over stdio, standard library only).

Started by Claude Code for one planning cycle:
    python mcp_server.py --state <snapshot.json> --out <orders.json> --memory <memory.json>

Query tools read the snapshot the mission sent for this cycle. Order tools
check each order against that snapshot (so Claude gets an immediate, specific
error instead of a silent failure) and append accepted orders to --out, which
the sidecar turns into the mission's orders file when the cycle ends. The
mission validates everything again when it executes.
"""

from __future__ import annotations

import argparse
import json
import math
import sys

PROTOCOL_FALLBACK = "2025-06-18"
MAX_TOOL_CALLS = 80
RETARGETABLE = {"CAP", "CAS", "SEAD", "RUNWAYSTRIKE"}
AIR_SPEED_KT = {"air": 420, "helicopter": 110, "surface": 20}
UPGRADE_CATEGORIES = ["sam", "shorad", "aaa", "armor", "ground", "arty"]
PURCHASE_ITEMS = ["upgrade", "warehouse", "warehouse_repair", "mass_attack", "bomber"]
PLAYER_TASK_ROLES = ["CAS", "SEAD", "DEAD", "CAPTURE", "RUNWAYSTRIKE", "ATTACK_SUPPORT", "RECON"]
TRIGGERS = ["enemy_air_near", "zone_attacked", "zone_lost"]


class GameTools:
    def __init__(self, state: dict, out_path: str, memory: dict):
        self.state = state
        self.p = state.get("payload") or {}
        self.side = self.p.get("side") or state.get("side")
        self.out_path = out_path
        self.memory = memory or {}
        self.orders: list[dict] = []
        self.summary = ""
        self.notes = ""
        self.finished = False
        self.calls = 0
        self.zones = {z["name"]: z for z in self.p.get("zones", [])}
        self.caps = {c["id"]: c for c in self.p.get("capabilities", [])}
        self.credits = (self.p.get("economy") or {}).get("credits", 0)
        self.spent = 0
        self.queued_caps: set[str] = set()
        ff = self.p.get("freeform") or {}
        self.roles = {r["role"]: r for r in ff.get("roles", [])}
        self.air_origins = {o["zone"]: o for o in ff.get("airOrigins", [])}
        self.save()

    # -- helpers ---------------------------------------------------------
    def save(self):
        with open(self.out_path, "w", encoding="utf-8") as f:
            json.dump({"orders": self.orders, "summary": self.summary, "notes": self.notes,
                       "finished": self.finished, "toolCalls": self.calls}, f, indent=1)

    def dist_nm(self, a: str, b: str) -> float | None:
        za, zb = self.zones.get(a), self.zones.get(b)
        if not za or not zb or za.get("xKm") is None or zb.get("xKm") is None:
            return None
        return math.hypot(za["xKm"] - zb["xKm"], za["zKm"] - zb["zKm"]) / 1.852

    def eta_min(self, a: str, b: str, domain: str) -> int | None:
        d = self.dist_nm(a, b)
        if d is None:
            return None
        return round(d / AIR_SPEED_KT.get(domain, 420) * 60)

    def own(self, name: str) -> bool:
        z = self.zones.get(name)
        return bool(z and z.get("side") == self.side)

    def add_order(self, order: dict, delay_min) -> str:
        if delay_min:
            order["delaySec"] = int(max(0, min(60, float(delay_min))) * 60)
        order["id"] = f"c{len(self.orders) + 1}"
        self.orders.append(order)
        self.save()
        when = f" in {order['delaySec'] // 60} min" if order.get("delaySec") else " now"
        return f"queued {order['id']}: {order['type']}{when}"

    def cap_row(self, c: dict) -> dict:
        row = {k: c.get(k) for k in ("id", "origin", "target", "role", "mission", "domain")}
        row["distanceNm"] = round(self.dist_nm(c["origin"], c["target"]) or 0)
        row["etaMin"] = self.eta_min(c["origin"], c["target"], "air" if c.get("domain") != "surface" else "surface")
        if c.get("state"):
            row["status"] = c["state"]
        elif c.get("available") is False:
            row["status"] = "unavailable: " + str(c.get("reason"))
        elif c.get("available") is None:
            row["status"] = "supply (stock-dependent)"
        else:
            row["status"] = "available"
        if c.get("freeform"):
            row["freeform"] = True
        return row

    # -- query tools -----------------------------------------------------
    def get_overview(self):
        p = self.p
        counts = {}
        for z in self.zones.values():
            counts[z["side"]] = counts.get(z["side"], 0) + 1
        front_own = sorted(n for n, z in self.zones.items() if z.get("frontline") and z["side"] == self.side)
        front_enemy = sorted(n for n, z in self.zones.items()
                             if z.get("frontline") and z["side"] not in (self.side, "neutral"))
        caps = list(self.caps.values())
        out = {
            "side": self.side,
            "reason": p.get("reason"),
            "missionClockMin": p.get("missionClockMin"),
            "economy": p.get("economy"),
            "zoneCounts": counts,
            "ownFrontline": front_own,
            "enemyFrontline": front_enemy,
            "capabilitiesAvailable": sum(1 for c in caps if c.get("available")),
            "capabilitiesTotal": len(caps),
            "activeMissions": [m for m in p.get("missions", []) if not m.get("outcome")],
            "recentlyEndedMissions": [m for m in p.get("missions", []) if m.get("outcome")],
            "detectedEnemyAircraft": len(p.get("detectedEnemyAir", [])),
            "eventsSinceLastCycle": p.get("events", []),
            "orderResultsSinceLastCycle": p.get("orderResults", []),
            "standingOrders": p.get("standingOrders", []),
            "supplyPriorities": p.get("supplyPriorities") or {},
            "yourNotesFromLastCycle": self.memory.get("notes", ""),
            "recentCycles": self.memory.get("history", [])[:5],
        }
        if self.side == "red":
            out["purchases"] = p.get("purchases")
            out["scriptedEvents"] = p.get("scriptedEvents")
        else:
            out["friendlyPlayers"] = p.get("friendlyPlayers")
            out["playerTasking"] = p.get("playerTasking")
        return out

    def list_zones(self, filter="all"):
        rows = []
        for z in self.zones.values():
            side = z["side"]
            if filter == "own" and side != self.side:
                continue
            if filter == "enemy" and side in (self.side, "neutral"):
                continue
            if filter == "neutral" and side != "neutral":
                continue
            if filter == "frontline" and not z.get("frontline"):
                continue
            rows.append({k: z.get(k) for k in ("name", "side", "facility", "groups", "maxGroups", "income",
                                               "needsSupply", "depot", "frontline", "suspended", "neighbors")})
        return sorted(rows, key=lambda r: r["name"])

    def get_zone(self, zone):
        z = self.zones.get(zone)
        if not z:
            raise ValueError(f"unknown zone {zone!r}; use list_zones")
        detail = dict(z)
        detail["neighbors"] = [{"zone": n, "side": self.zones.get(n, {}).get("side"),
                                "distanceNm": round(self.dist_nm(zone, n) or 0)} for n in z.get("neighbors", [])]
        detail["capabilitiesFromHere"] = [self.cap_row(c) for c in self.caps.values() if c["origin"] == zone]
        detail["capabilitiesTargetingHere"] = [self.cap_row(c) for c in self.caps.values() if c["target"] == zone]
        detail["nearestOwnAirOrigins"] = sorted(
            ({"zone": o, "distanceNm": round(self.dist_nm(o, zone) or 0)} for o in self.air_origins),
            key=lambda r: r["distanceNm"])[:5]
        return detail

    def list_capabilities(self, origin=None, target=None, role=None, available_only=False):
        rows = []
        for c in self.caps.values():
            if origin and c["origin"] != origin:
                continue
            if target and c["target"] != target:
                continue
            if role and (c.get("role") or c.get("mission")) != role and c.get("mission") != role:
                continue
            if available_only and not c.get("available"):
                continue
            rows.append(self.cap_row(c))
        return sorted(rows, key=lambda r: (r["origin"], r["target"], str(r["role"])))[:150]

    def list_missions(self):
        return self.p.get("missions", [])

    def list_enemy_air(self):
        return self.p.get("detectedEnemyAir", [])

    def list_freeform_options(self):
        return self.p.get("freeform", {})

    def list_purchase_options(self):
        return {"purchases": self.p.get("purchases"), "scriptedEvents": self.p.get("scriptedEvents")}

    def get_player_tasking(self):
        return self.p.get("playerTasking")

    # -- order tools -----------------------------------------------------
    def launch_capability(self, capability, target_zone=None, delay_min=0):
        c = self.caps.get(capability)
        if not c:
            raise ValueError(f"unknown capability {capability!r}; use list_capabilities")
        if c.get("mission") == "supply":
            raise ValueError("this is a supply capability; use order_supply_run")
        if c.get("state"):
            raise ValueError(f"{capability} is already {c['state']}")
        if c.get("available") is False:
            raise ValueError(f"{capability} is unavailable: {c.get('reason')}")
        if capability in self.queued_caps:
            raise ValueError(f"{capability} is already ordered this cycle")
        order = {"type": "launch_capability", "capability": capability}
        if target_zone and target_zone != c["target"]:
            if target_zone not in self.zones:
                raise ValueError(f"unknown target zone {target_zone!r}")
            if c.get("role") not in RETARGETABLE:
                raise ValueError(f"role {c.get('role')} cannot be sent to another target; "
                                 "use launch_mission for a free-form mission")
            order["targetZone"] = target_zone
        self.queued_caps.add(capability)
        target = order.get("targetZone", c["target"])
        eta = self.eta_min(c["origin"], target, "surface" if c.get("domain") == "surface" else "air")
        return self.add_order(order, delay_min) + f" ({c['origin']} -> {target}, about {eta} min flight)"

    def launch_mission(self, origin, role, target_zone, delay_min=0):
        r = self.roles.get(role)
        if not r:
            raise ValueError(f"role {role!r} not available for this side; options: {sorted(self.roles)}")
        if not self.own(origin):
            raise ValueError(f"{origin!r} is not one of your zones")
        if target_zone not in self.zones:
            raise ValueError(f"unknown target zone {target_zone!r}")
        if r.get("domain") == "air" and origin not in self.air_origins:
            raise ValueError(f"{origin} cannot launch aircraft; air origins: {sorted(self.air_origins)}")
        if role == "CAS_HELO" and not self.air_origins[origin].get("helicopters"):
            raise ValueError(f"{origin} cannot launch helicopters")
        if role != "CAS_HELO" and r.get("domain") == "air" and not self.air_origins[origin].get("planes"):
            raise ValueError(f"{origin} cannot launch planes")
        price = int(r.get("price", 0))
        if self.spent + price > self.credits:
            raise ValueError(f"not enough credits: {self.credits - self.spent} left this cycle, mission costs {price}")
        self.spent += price
        eta = self.eta_min(origin, target_zone, "surface" if r.get("domain") == "surface" else
                           ("helicopter" if role == "CAS_HELO" else "air"))
        return self.add_order({"type": "launch_mission", "origin": origin, "role": role,
                               "targetZone": target_zone}, delay_min) + \
            f" (cost {price}, about {eta} min to target; the mission re-checks aircraft and stock at launch)"

    def purchase(self, item, zone=None, category=None, targets=None):
        if self.side != "red":
            raise ValueError("purchases are RED only")
        if item not in PURCHASE_ITEMS:
            raise ValueError(f"item must be one of {PURCHASE_ITEMS}")
        options = self.p.get("purchases") or {}
        costs = {i["item"]: i["cost"] for i in options.get("items", [])}
        if item not in costs:
            raise ValueError(f"{item} is not sold in this mission")
        order = {"type": "purchase", "item": item}
        if item == "upgrade":
            if zone not in (options.get("upgradeZones") or []):
                raise ValueError(f"upgrade zone must be one of {options.get('upgradeZones')}")
            if category and category not in UPGRADE_CATEGORIES:
                raise ValueError(f"category must be one of {UPGRADE_CATEGORIES}")
            order["zone"], order["category"] = zone, category
        elif item in ("warehouse", "warehouse_repair"):
            if not self.own(zone or ""):
                raise ValueError("depot zone must be one of your zones")
            order["zone"] = zone
        else:
            valid = [t for t in (targets or []) if t in self.zones and not self.own(t)]
            if not valid:
                raise ValueError("give at least one enemy target zone in targets")
            order["targets"] = valid
        if self.spent + costs[item] > self.credits:
            raise ValueError(f"not enough credits: {self.credits - self.spent} left, {item} costs {costs[item]}")
        self.spent += costs[item]
        return self.add_order(order, 0) + f" (cost about {costs[item]})"

    def set_supply_priority(self, zone, priority):
        if zone not in self.zones:
            raise ValueError(f"unknown zone {zone!r}")
        if priority not in ("high", "normal", "low", "none"):
            raise ValueError("priority must be high, normal, low or none")
        return self.add_order({"type": "supply_priority", "zone": zone, "priority": priority}, 0)

    def order_supply_run(self, capability, delay_min=0):
        c = self.caps.get(capability)
        if not c or c.get("mission") != "supply":
            raise ValueError("not a supply capability; use list_capabilities with role 'supply'")
        return self.add_order({"type": "supply_run", "capability": capability}, delay_min)

    def set_player_tasks(self, role, zones):
        if self.side != "blue":
            raise ValueError("player tasking is BLUE only")
        if role not in PLAYER_TASK_ROLES:
            raise ValueError(f"role must be one of {PLAYER_TASK_ROLES}")
        unknown = [z for z in zones if z not in self.zones]
        if unknown:
            raise ValueError(f"unknown zones: {unknown}")
        return self.add_order({"type": "player_tasks", "role": role, "zones": list(zones)}, 0)

    def set_standing_orders(self, rules):
        clean = []
        for i, r in enumerate(rules):
            rid = r.get("id") or f"rule{i + 1}"
            if r.get("trigger") not in TRIGGERS:
                raise ValueError(f"{rid}: trigger must be one of {TRIGGERS}")
            if r.get("trigger") == "zone_attacked" and self.side != "red":
                raise ValueError(f"{rid}: zone_attacked is only reported for RED zones")
            zone = r.get("zone")
            if zone != "*" and zone not in self.zones:
                raise ValueError(f"{rid}: unknown zone {zone!r} (use '*' for any own zone)")
            a = r.get("action") or {}
            if a.get("type") == "launch_capability":
                c = self.caps.get(a.get("capability"))
                if not c or c.get("mission") == "supply":
                    raise ValueError(f"{rid}: unknown or supply capability {a.get('capability')!r}")
                action = {"type": "launch_capability", "capability": c["id"]}
                if a.get("target_zone"):
                    if c.get("role") not in RETARGETABLE:
                        raise ValueError(f"{rid}: {c['id']} cannot be retargeted")
                    action["targetZone"] = a["target_zone"]
            elif a.get("type") == "launch_mission":
                if a.get("role") not in self.roles or not self.own(a.get("origin", "")):
                    raise ValueError(f"{rid}: launch_mission needs an own origin and a valid role")
                action = {"type": "launch_mission", "origin": a["origin"], "role": a["role"],
                          "targetZone": a.get("target_zone") or "$zone"}
            else:
                raise ValueError(f"{rid}: action.type must be launch_capability or launch_mission")
            clean.append({"id": rid, "trigger": r["trigger"], "zone": zone,
                          "radiusNm": r.get("radius_nm", 40), "minContacts": r.get("min_contacts", 1),
                          "cooldownSec": int(r.get("cooldown_min", 10) * 60), "maxActive": r.get("max_active", 1),
                          "action": action})
        return self.add_order({"type": "standing_orders", "rules": clean}, 0) + \
            f" ({len(clean)} rules; replaces all previous standing orders)"

    def trigger_event(self, event):
        if self.side != "red":
            raise ValueError("scripted events are RED only")
        events = {e["event"]: e for e in self.p.get("scriptedEvents") or []}
        if event not in events:
            raise ValueError(f"unknown event; options: {sorted(events)}")
        if not events[event].get("available"):
            raise ValueError(f"{event} cannot run right now")
        return self.add_order({"type": "trigger_event", "event": event}, 0)

    def send_hq_message(self, text):
        if self.side != "blue":
            raise ValueError("HQ messages are BLUE only")
        return self.add_order({"type": "hq_message", "text": str(text)[:400]}, 0)

    def finish_cycle(self, summary, notes=""):
        self.summary = str(summary)[:600]
        self.notes = str(notes)[:2000]
        self.finished = True
        self.save()
        return f"Cycle complete with {len(self.orders)} orders. Stop now."


def _s(type_, desc=None, **extra):
    d = {"type": type_}
    if desc:
        d["description"] = desc
    d.update(extra)
    return d


def tool_specs(side: str) -> list[dict]:
    obj = lambda props, req=(): {"type": "object", "properties": props, "required": list(req),  # noqa: E731
                                 "additionalProperties": False}
    delay = _s("number", "Minutes to wait before launching (0-60). Use it to time packages to a common TOT.")
    specs = [
        ("get_overview", "Start here. Economy, front line, missions in progress, results of your last orders, "
                         "events since the last cycle, standing orders and your notes from last cycle.", obj({})),
        ("list_zones", "Zones with owner, defences (groups/maxGroups), income, supply need, depot and neighbours.",
         obj({"filter": _s("string", enum=["all", "own", "enemy", "neutral", "frontline"])})),
        ("get_zone", "Everything about one zone: neighbours with distances, capabilities from and to it, "
                     "nearest own air origins.", obj({"zone": _s("string")}, ["zone"])),
        ("list_capabilities", "Pre-built missions your zones can launch (origin -> target, role), with availability, "
                              "distance and flight time. Filter by origin, target or role (CAP, CAS, SEAD, "
                              "RUNWAYSTRIKE, ARTY, supply).",
         obj({"origin": _s("string"), "target": _s("string"), "role": _s("string"),
              "available_only": _s("boolean")})),
        ("list_missions", "Missions you launched: status, target, outcome.", obj({})),
        ("list_enemy_air", "Enemy aircraft your radars currently detect.", obj({})),
        ("list_freeform_options", "Free-form mission roles with prices, and your air origins.", obj({})),
        ("launch_capability", "Launch a pre-built capability now or after a delay. CAP/CAS/SEAD/RUNWAYSTRIKE "
                              "capabilities can be sent to a different target_zone.",
         obj({"capability": _s("string"), "target_zone": _s("string"), "delay_min": delay}, ["capability"])),
        ("launch_mission", "Free-form mission from any own origin to any target, paid from credits. "
                           "Roles: CAP (defensive patrol over target), SWEEP (fighter sweep), CAS, CAS_HELO, SEAD, "
                           "RUNWAY_STRIKE, CONVOY, ARTY.",
         obj({"origin": _s("string"), "role": _s("string"), "target_zone": _s("string"), "delay_min": delay},
             ["origin", "role", "target_zone"])),
        ("set_supply_priority", "Steer the automatic supply dispatcher for a zone: high, normal, low, or none "
                                "(starve it).",
         obj({"zone": _s("string"), "priority": _s("string", enum=["high", "normal", "low", "none"])},
             ["zone", "priority"])),
        ("order_supply_run", "Send one supply run now (uses a supply capability; needs stock at the origin).",
         obj({"capability": _s("string"), "delay_min": delay}, ["capability"])),
        ("set_standing_orders", "Replace ALL standing orders. They run instantly in the mission between cycles. "
                                "Triggers: enemy_air_near (radar contacts within radius_nm of zone), zone_attacked "
                                "(RED zones only), zone_lost. zone may be '*' for any own zone. In actions, "
                                "target_zone '$zone' means the zone that triggered.",
         obj({"rules": {"type": "array", "items": obj({
             "id": _s("string"),
             "trigger": _s("string", enum=TRIGGERS),
             "zone": _s("string"),
             "radius_nm": _s("number"),
             "min_contacts": _s("integer"),
             "cooldown_min": _s("number"),
             "max_active": _s("integer"),
             "action": obj({"type": _s("string", enum=["launch_capability", "launch_mission"]),
                            "capability": _s("string"), "origin": _s("string"), "role": _s("string"),
                            "target_zone": _s("string")}, ["type"]),
         }, ["id", "trigger", "zone", "action"])}}, ["rules"])),
        ("finish_cycle", "End the cycle. summary: what you did and why (logged). notes: what you want to remember "
                         "next cycle (plans in progress, intended timings, things to check).",
         obj({"summary": _s("string"), "notes": _s("string")}, ["summary"])),
    ]
    if side == "red":
        specs += [
            ("list_purchase_options", "RED purchases (zone upgrades, depots, mass attack, bomber) and scripted "
                                      "events, with costs and cooldowns.", obj({})),
            ("purchase", "Buy for RED. upgrade needs zone and optional category (sam, shorad, aaa, armor, ground, "
                         "arty); warehouse/warehouse_repair need zone; mass_attack/bomber need targets.",
             obj({"item": _s("string", enum=PURCHASE_ITEMS), "zone": _s("string"),
                  "category": _s("string", enum=UPGRADE_CATEGORIES),
                  "targets": {"type": "array", "items": _s("string")}}, ["item"])),
            ("trigger_event", "Start one of the mission's scripted RED events.", obj({"event": _s("string")},
                                                                                    ["event"])),
        ]
    else:
        specs += [
            ("get_player_tasking", "Player mission roles, your current designations and the zones Foothold last "
                                   "offered as candidates per role.", obj({})),
            ("set_player_tasks", "Choose which zones are offered to players for a mission role, in priority order. "
                                 "Players get no missions of a role you have not designated.",
             obj({"role": _s("string", enum=PLAYER_TASK_ROLES), "zones": {"type": "array", "items": _s("string")}},
                 ["role", "zones"])),
            ("send_hq_message", "Short message shown to BLUE players as 'HQ: ...'.", obj({"text": _s("string")},
                                                                                        ["text"])),
        ]
    return [{"name": n, "description": d, "inputSchema": s} for n, d, s in specs]


def serve(tools: GameTools, stdin=sys.stdin, stdout=sys.stdout):
    specs = {t["name"]: t for t in tool_specs(tools.side)}

    def send(msg):
        stdout.write(json.dumps(msg) + "\n")
        stdout.flush()

    for line in stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except json.JSONDecodeError:
            continue
        method, mid = msg.get("method"), msg.get("id")
        if method == "initialize":
            version = (msg.get("params") or {}).get("protocolVersion") or PROTOCOL_FALLBACK
            send({"jsonrpc": "2.0", "id": mid, "result": {
                "protocolVersion": version, "capabilities": {"tools": {}},
                "serverInfo": {"name": "foothold", "version": "0.2"}}})
        elif method == "tools/list":
            send({"jsonrpc": "2.0", "id": mid, "result": {"tools": list(specs.values())}})
        elif method == "tools/call":
            params = msg.get("params") or {}
            name, args = params.get("name"), params.get("arguments") or {}
            tools.calls += 1
            try:
                if name not in specs:
                    raise ValueError(f"unknown tool {name}")
                if tools.finished:
                    raise ValueError("cycle already finished; stop now")
                if tools.calls > MAX_TOOL_CALLS and name != "finish_cycle":
                    raise ValueError("tool budget for this cycle used up; call finish_cycle now")
                result = getattr(tools, name)(**args)
                text = result if isinstance(result, str) else json.dumps(result, separators=(",", ":"))
                send({"jsonrpc": "2.0", "id": mid, "result": {"content": [{"type": "text", "text": text}]}})
            except (ValueError, TypeError) as exc:
                send({"jsonrpc": "2.0", "id": mid, "result": {
                    "content": [{"type": "text", "text": f"Error: {exc}"}], "isError": True}})
            tools.save()
        elif mid is not None:
            send({"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": f"unknown method {method}"}})


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--state", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--memory", required=True)
    args = ap.parse_args(argv)
    with open(args.state, encoding="utf-8") as f:
        state = json.load(f)
    try:
        with open(args.memory, encoding="utf-8") as f:
            memory = json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        memory = {}
    serve(GameTools(state, args.out, memory))


if __name__ == "__main__":
    main()
