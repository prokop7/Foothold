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
import re
import sys

PROTOCOL_FALLBACK = "2025-06-18"
MAX_TOOL_CALLS = 80
RETARGETABLE = {"CAP", "CAS", "SEAD", "RUNWAYSTRIKE"}
AIR_SPEED_KT = {"air": 420, "helicopter": 110, "surface": 20}
UPGRADE_CATEGORIES = ["sam", "shorad", "aaa", "armor", "ground", "arty"]
PURCHASE_ITEMS = ["upgrade", "warehouse", "warehouse_repair", "mass_attack", "bomber"]
PLAYER_TASK_ROLES = ["CAS", "SEAD", "DEAD", "CAPTURE", "RUNWAYSTRIKE", "ATTACK_SUPPORT", "RECON"]
TRIGGERS = ["enemy_air_near", "zone_attacked", "zone_lost"]
# Pre-built capability role -> free-form role whose price the capability fee is based on.
FEE_ROLE = {"CAP": "CAP", "CAS": "CAS", "SEAD": "SEAD", "RUNWAYSTRIKE": "RUNWAY_STRIKE"}
NUMERIC_ARGS = ("delay_min", "fraction", "heading_deg", "leg_nm", "push_in_min", "ip_nm", "push_offset_min")


def sanitize_id(text: str) -> str:
    """Same as the mission's sanitizeId: runs of non-alphanumerics become '_'."""
    return re.sub(r"[^0-9A-Za-z]+", "_", str(text))


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
        self.ops = self.p.get("operations") or {}
        self.deploy_queued: dict[str, int] = {}
        self.ops_queued: set = set()
        self.freeform_queued: set[str] = set()
        self.packages = {pk["package"]: pk for pk in self.p.get("packages", [])}
        self.packages_queued: dict[str, dict] = {}
        self.flights_queued = 0
        self.ambush_queued = 0
        self.purchased = False
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

    def spend(self, price: int, what: str):
        price = int(price or 0)
        if self.spent + price > self.credits:
            raise ValueError(f"not enough credits: {self.credits - self.spent} left this cycle, {what} costs {price}")
        self.spent += price

    def cap_fee(self, c: dict) -> int:
        if c.get("freeform") and c.get("price") is not None:
            return int(c["price"])   # a free-form mission launched again costs its price again
        frac = (self.p.get("economy") or {}).get("capabilityFee") or 0
        if not frac or c.get("mission") == "supply":
            return 0
        role = self.roles.get(FEE_ROLE.get(c.get("role"), "CONVOY")) or {}
        return int((role.get("price") or 1000) * frac)

    def package_fields(self, order: dict, package, push_offset_min, delay_min) -> str:
        """Adds package membership to a launch order; returns a note for the result."""
        if package is None:
            return ""
        pkg = self.packages_queued.get(package) or self.packages.get(package)
        if not pkg:
            raise ValueError(f"unknown package {package!r}; create it first with create_package")
        if pkg.get("pushedMinAgo") is not None:
            raise ValueError(f"package {package} has already pushed")
        if delay_min:
            raise ValueError("package flights launch now and hold at the IP; do not combine with delay_min")
        order["package"] = package
        offset = float(push_offset_min or 0)
        if offset:
            order["pushOffsetMin"] = max(-10.0, min(10.0, offset))
        return f"; joins package {package}" + (f", pushes {order['pushOffsetMin']:+g} min" if offset else "")

    def red_only(self, what: str):
        if self.side != "red":
            raise ValueError(f"{what} is RED only")
        if not self.ops:
            raise ValueError("RED operations are not loaded in this mission (Foothold_AI_Ops.lua)")

    def zone_km(self, a: str, b: str) -> float | None:
        d = self.dist_nm(a, b)
        return None if d is None else d * 1.852

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
            "delayedOrdersPending": p.get("scheduledOrders", []),
            "packages": p.get("packages", []),
            "supplyPriorities": p.get("supplyPriorities") or {},
            "yourNotesFromLastCycle": self.memory.get("notes", ""),
            "recentCycles": self.memory.get("history", [])[:5],
        }
        if self.side == "red":
            out["purchases"] = p.get("purchases")
            out["scriptedEvents"] = p.get("scriptedEvents")
            ops = p.get("operations") or {}
            out["operationsInProgress"] = {k: ops.get(k) for k in ("flights", "groundTeams", "batteries", "deployed")}
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

    def list_operations(self):
        self.red_only("operations")
        return self.ops

    # -- order tools -----------------------------------------------------
    def launch_capability(self, capability, target_zone=None, delay_min=0, package=None, push_offset_min=0):
        delay_min = float(delay_min or 0)
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
        if package is not None and c.get("domain") == "surface":
            raise ValueError("ground units cannot hold at an IP; launch them without a package")
        note = self.package_fields(order, package, push_offset_min, delay_min)
        fee = self.cap_fee(c)
        if fee:
            self.spend(fee, f"the sortie fee for {capability}")
        self.queued_caps.add(capability)
        target = order.get("targetZone", c["target"])
        eta = self.eta_min(c["origin"], target, "surface" if c.get("domain") == "surface" else "air")
        return self.add_order(order, delay_min) + f" ({c['origin']} -> {target}, about {eta} min flight{note})"

    def launch_mission(self, origin, role, target_zone, delay_min=0, template=None, package=None, push_offset_min=0):
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
        if template is not None and template not in (r.get("templates") or []):
            raise ValueError(f"template {template!r} is not a {role} template; options: {r.get('templates') or []}")
        ff_id = f"FAI-{self.side}-{sanitize_id(origin)}-{sanitize_id(target_zone)}-{role}"
        if template is not None:
            ff_id += "-" + sanitize_id(template)
        existing = self.caps.get(ff_id)
        if ff_id in self.freeform_queued or (existing and existing.get("state")):
            raise ValueError(f"the same {role} mission from {origin} to {target_zone} is already flying or ordered; "
                             "use another origin, role or template")
        order = {"type": "launch_mission", "origin": origin, "role": role, "targetZone": target_zone}
        if template is not None:
            order["template"] = template
        if package is not None and r.get("domain") == "surface":
            raise ValueError("ground units cannot hold at an IP; launch them without a package")
        note = self.package_fields(order, package, push_offset_min, delay_min)
        price = int(r.get("price", 0))
        self.spend(price, "the mission")   # last check: nothing is reserved if an earlier one fails
        self.freeform_queued.add(ff_id)
        eta = self.eta_min(origin, target_zone, "surface" if r.get("domain") == "surface" else
                           ("helicopter" if role == "CAS_HELO" else "air"))
        return self.add_order(order, delay_min) + note + \
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
        if self.purchased:
            raise ValueError("one purchase per cycle: Foothold starts a purchase cooldown after each one")
        if options.get("purchaseCooldownSec"):
            raise ValueError(f"purchases are on cooldown for {options['purchaseCooldownSec'] // 60 + 1} more min")
        if item == "upgrade" and options.get("upgradeCooldownSec"):
            raise ValueError(f"zone upgrades are on cooldown for {options['upgradeCooldownSec'] // 60 + 1} more min")
        if item == "mass_attack" and options.get("massAttackCooldownSec"):
            raise ValueError(f"mass attack possible again in {options['massAttackCooldownSec'] // 60 + 1} min")
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
        self.purchased = True
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
        limit = self.p.get("standingOrdersMax")
        if limit and len(rules) > limit:
            raise ValueError(f"at most {limit} standing orders; you gave {len(rules)}")
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
            wait = events[event].get("readyInMin")
            raise ValueError(f"{event} cannot run right now" + (f" (possible again in {wait} min)" if wait else ""))
        if ("event", event) in self.ops_queued:
            raise ValueError(f"{event} is already ordered this cycle")
        price = int(events[event].get("price") or 0)
        self.spend(price, f"the {event} event")
        self.ops_queued.add(("event", event))
        return self.add_order({"type": "trigger_event", "event": event}, 0) + f" (cost {price})"

    def send_hq_message(self, text):
        if self.side != "blue":
            raise ValueError("HQ messages are BLUE only")
        return self.add_order({"type": "hq_message", "text": str(text)[:400]}, 0)

    # -- RED operations ----------------------------------------------------
    def deploy_forces(self, zone, template):
        self.red_only("deploy_forces")
        if not self.own(zone):
            raise ValueError(f"{zone!r} is not one of your zones")
        entry = next((e for e in self.ops.get("deployCatalog", []) if e["template"] == template), None)
        if not entry:
            raise ValueError("unknown template; see list_operations deployCatalog")
        limits = self.ops.get("deployLimits") or {}
        in_zone = sum(1 for d in self.ops.get("deployed", []) if d["zone"] == zone) + self.deploy_queued.get(zone, 0)
        total = len(self.ops.get("deployed", [])) + sum(self.deploy_queued.values())
        if in_zone >= limits.get("perZone", 2):
            raise ValueError(f"{zone} already has {in_zone} deployed groups (limit {limits.get('perZone')})")
        if total >= limits.get("total", 12):
            raise ValueError("deployed group limit reached")
        price = (self.ops.get("prices") or {}).get("deploy", {}).get(entry["category"], 0)
        self.spend(price, template)
        self.deploy_queued[zone] = self.deploy_queued.get(zone, 0) + 1
        return self.add_order({"type": "deploy_forces", "zone": zone, "template": template}, 0) + \
            f" ({entry['category']}, cost {price})"

    def upgrade_zone(self, zone, template):
        self.red_only("upgrade_zone")
        slot = next((s for s in self.ops.get("upgradeSlots", []) if s["zone"] == zone), None)
        if not slot:
            raise ValueError(f"{zone} has no free upgrade slot; zones with one: "
                             f"{[s['zone'] for s in self.ops.get('upgradeSlots', [])]}")
        category = next((c for c, names in slot["templates"].items() if template in names), None)
        if not category:
            raise ValueError(f"{zone} does not take {template!r}; options: {slot['templates']}")
        if ("upgrade", zone) in self.ops_queued:
            raise ValueError(f"{zone} is already being upgraded this cycle")
        deploy_prices = (self.ops.get("prices") or {}).get("deploy", {})
        price = (slot.get("prices") or {}).get(template, deploy_prices.get(category, deploy_prices.get("other", 0)))
        self.spend(price, template)
        self.ops_queued.add(("upgrade", zone))
        return self.add_order({"type": "upgrade_zone", "zone": zone, "template": template}, 0) + \
            f" ({category}, cost about {price}; permanent defender of {zone})"

    def fire_mission(self, system, origin, target_zone, delay_min=0):
        self.red_only("fire_mission")
        delay_min = float(delay_min or 0)
        sysrow = next((s for s in self.ops.get("fireSystems", []) if s["system"] == system), None)
        if not sysrow:
            raise ValueError(f"unknown system; options: {[s['system'] for s in self.ops.get('fireSystems', [])]}")
        if sysrow.get("readyInMin"):
            raise ValueError(f"{system} is reloading for {sysrow['readyInMin']} more min")
        if ("fire", system) in self.ops_queued:
            raise ValueError(f"{system} is already ordered this cycle")
        if not self.own(origin):
            raise ValueError(f"{origin!r} is not one of your zones")
        z = self.zones.get(target_zone)
        if not z or z["side"] in (self.side, "neutral"):
            raise ValueError("target must be an enemy zone")
        km = self.zone_km(origin, target_zone)
        if km is not None and km > sysrow["rangeKm"]:
            raise ValueError(f"{target_zone} is {round(km)} km from {origin}; {system} reaches {sysrow['rangeKm']} km")
        self.spend(sysrow["price"], f"a {system} fire mission")
        self.ops_queued.add(("fire", system))
        return self.add_order({"type": "fire_mission", "system": system, "origin": origin,
                               "targetZone": target_zone}, delay_min) + \
            f" (cost {sysrow['price']}; the battery sets up in {origin}, fires about 1 min later and stays " \
            "there as a target for a while)"

    def move_awacs(self, zone, heading_deg=0, leg_nm=20):
        self.red_only("move_awacs")
        if not (self.ops.get("awacs") or {}).get("available"):
            raise ValueError("no RED AWACS in this mission")
        if not self.own(zone):
            raise ValueError("the AWACS orbits over your own zones")
        if self.ops.get("awacsReadyInMin"):
            raise ValueError(f"the AWACS can move again in {self.ops['awacsReadyInMin']} min")
        if "awacs" in self.ops_queued:
            raise ValueError("the AWACS is already ordered to move this cycle")
        self.ops_queued.add("awacs")
        price = (self.ops.get("prices") or {}).get("awacs", 0)
        self.spend(price, "moving the AWACS")
        return self.add_order({"type": "move_awacs", "zone": zone, "headingDeg": heading_deg, "legNm": leg_nm}, 0)

    def supply_airlift(self, zone):
        self.red_only("supply_airlift")
        if not self.own(zone):
            raise ValueError(f"{zone!r} is not one of your zones")
        price = (self.ops.get("prices") or {}).get("airlift", 0)
        self.spend(price, "the airlift")
        return self.add_order({"type": "supply_airlift", "zone": zone}, 0) + \
            f" (cost {price}, adds {self.ops.get('airliftUnits', 3)} supply units)"

    def _flight_slot(self, ambush=False):
        limits = self.ops.get("limits") or {}
        flying = len(self.ops.get("flights", [])) + self.flights_queued
        if limits.get("activeFlights") and flying >= limits["activeFlights"]:
            raise ValueError(f"{flying} RED operations already flying or ordered (limit {limits['activeFlights']})")
        if ambush and limits.get("ambushTeams"):
            teams = sum(1 for t in self.ops.get("groundTeams", []) if t.get("kind") == "ambush")
            teams += sum(1 for f in self.ops.get("flights", []) if f.get("operation") == "ambush") + self.ambush_queued
            if teams >= limits["ambushTeams"]:
                raise ValueError(f"{teams} ambush teams already out or ordered (limit {limits['ambushTeams']})")

    def _helo_origin(self, origin, target):
        if origin not in (self.ops.get("heloOrigins") or []):
            raise ValueError(f"{origin!r} cannot launch helicopters; options: {self.ops.get('heloOrigins')}")
        km = self.zone_km(origin, target)
        limit = self.ops.get("heloRangeKm", 150)
        if km is not None and km > limit + 10:
            raise ValueError(f"{target} is {round(km)} km from {origin}; helicopter operations reach {limit} km")

    def heli_raid(self, origin, target_zone, gun="akatsia", delay_min=0):
        self.red_only("heli_raid")
        guns = {g["gun"]: g for g in self.ops.get("raidGuns", [])}
        if gun not in guns:
            raise ValueError(f"gun must be one of {sorted(guns)}")
        z = self.zones.get(target_zone)
        if not z or z["side"] in (self.side, "neutral"):
            raise ValueError("target must be an enemy zone")
        self._helo_origin(origin, target_zone)
        self._flight_slot()
        delay_min = float(delay_min or 0)
        price = (self.ops.get("prices") or {}).get("heli_raid", 0)
        self.spend(price, "the raid")
        self.flights_queued += 1
        return self.add_order({"type": "heli_raid", "origin": origin, "targetZone": target_zone, "gun": gun},
                              delay_min) + \
            f" (cost {price}; a Mi-8 lands the gun about {round(guns[gun]['rangeKm'] * 0.8)} km from {target_zone}" \
            " on your side, the gun fires, the helicopter flies home)"

    def air_assault(self, origin, target_zone, delay_min=0):
        self.red_only("air_assault")
        z = self.zones.get(target_zone)
        if not z or z["side"] != "neutral":
            raise ValueError("air assault needs a neutral zone")
        self._helo_origin(origin, target_zone)
        self._flight_slot()
        delay_min = float(delay_min or 0)
        price = (self.ops.get("prices") or {}).get("air_assault", 0)
        self.spend(price, "the air assault")
        self.flights_queued += 1
        return self.add_order({"type": "air_assault", "origin": origin, "targetZone": target_zone}, delay_min) + \
            f" (cost {price}; the troops capture the zone if they survive the capture time)"

    def ambush(self, origin, from_zone, toward_zone, fraction=0.5, team="manpads", delay_min=0):
        self.red_only("ambush")
        if team not in (self.ops.get("ambushTeams") or []):
            raise ValueError(f"team must be one of {self.ops.get('ambushTeams')}")
        if from_zone not in self.zones or toward_zone not in self.zones:
            raise ValueError("from_zone and toward_zone must be known zones")
        self._helo_origin(origin, from_zone)
        self._flight_slot(ambush=True)
        fraction = max(0.1, min(0.9, float(fraction)))
        delay_min = float(delay_min or 0)
        price = (self.ops.get("prices") or {}).get("ambush", 0)
        self.spend(price, "the ambush team")
        self.flights_queued += 1
        self.ambush_queued += 1
        return self.add_order({"type": "ambush", "origin": origin, "fromZone": from_zone, "towardZone": toward_zone,
                               "fraction": fraction, "team": team}, delay_min) + \
            f" (cost {price})"

    def jam(self, target_zone, delay_min=0):
        self.red_only("jam")
        jammer = self.ops.get("jammer") or {}
        if jammer.get("unavailable"):
            raise ValueError(jammer["unavailable"])
        if any(f.get("operation") == "jam" for f in self.ops.get("flights", [])) or "jam" in self.ops_queued:
            raise ValueError("a jammer is already flying or ordered")
        z = self.zones.get(target_zone)
        if not z or z["side"] in (self.side, "neutral"):
            raise ValueError("target must be an enemy zone")
        self._flight_slot()
        delay_min = float(delay_min or 0)
        price = (self.ops.get("prices") or {}).get("jam", 0)
        self.spend(price, "the jammer")
        self.flights_queued += 1
        self.ops_queued.add("jam")
        return self.add_order({"type": "jam", "targetZone": target_zone}, delay_min) + \
            f" (cost {price}; SAM radars of {target_zone} within {jammer.get('rangeNm')} nm of the jammer " \
            f"({jammer.get('longRangeSamRangeNm')} nm for long-range SAMs) hold fire " \
            f"for up to {jammer.get('minutes')} min while it lives - escort it)"

    def create_package(self, package, target_zone, push_in_min=20, ip_nm=30, from_zone=None, push_when_ready=True):
        if not isinstance(package, str) or not package.strip():
            raise ValueError("package needs a short name")
        package = "".join(ch if ch.isalnum() or ch in "-_" else "_" for ch in package)[:30]
        existing = self.packages.get(package)
        if package in self.packages_queued or (existing and existing.get("pushedMinAgo") is None):
            raise ValueError(f"package {package} already exists and has not pushed")
        if target_zone not in self.zones:
            raise ValueError(f"unknown target zone {target_zone!r}")
        if from_zone is not None and not self.own(from_zone):
            raise ValueError("from_zone must be one of your zones")
        push = max(10.0, min(45.0, float(push_in_min)))
        order = {"type": "create_package", "package": package, "targetZone": target_zone, "pushInMin": push,
                 "ipNm": max(10.0, min(80.0, float(ip_nm))), "pushWhenReady": bool(push_when_ready)}
        if from_zone is not None:
            order["fromZone"] = from_zone
        self.packages_queued[package] = order
        note = " (push time moved to the 10-45 min range)" if push != float(push_in_min) else ""
        return self.add_order(order, 0) + f"{note}. Now launch its flights with package={package!r}."

    def list_packages(self):
        return self.p.get("packages", [])

    def cancel_orders(self, order_ids):
        pending = {o["order"] for o in self.p.get("scheduledOrders", [])}
        unknown = [i for i in order_ids if i not in pending]
        if unknown:
            raise ValueError(f"not pending: {unknown}; pending delayed orders: {sorted(pending)}")
        return self.add_order({"type": "cancel_orders", "ids": list(order_ids)}, 0)

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
    delay = _s("number", "Minutes to wait before launching (0-60). For flights that must arrive together, "
                         "prefer a package.")
    pkg_arg = _s("string", "Package name from create_package: launch now, hold at its IP, push with it.")
    offset_arg = _s("number", "Minutes after (+) or before (-) the package push this flight leaves the IP, "
                              "e.g. SEAD 0, strike +2 (-10..10).")
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
                              "capabilities can be sent to a different target_zone. With package, the flight "
                              "launches now and holds at the package IP until the push.",
         obj({"capability": _s("string"), "target_zone": _s("string"), "delay_min": delay,
              "package": pkg_arg, "push_offset_min": offset_arg}, ["capability"])),
        ("launch_mission", "Free-form mission from any own origin to any target, paid from credits. "
                           "Roles: CAP (defensive patrol over target), SWEEP (fighter sweep), CAS, CAS_HELO, SEAD, "
                           "RUNWAY_STRIKE, CONVOY, ARTY. Optional template picks the exact aircraft and loadout "
                           "(list_freeform_options shows each role's templates); without it Foothold picks one.",
         obj({"origin": _s("string"), "role": _s("string"), "target_zone": _s("string"), "delay_min": delay,
              "template": _s("string"), "package": pkg_arg, "push_offset_min": offset_arg},
             ["origin", "role", "target_zone"])),
        ("create_package", "Create a strike package: its flights launch now, hold in an orbit at an IP ip_nm from "
                           "the target (toward from_zone, or your zone nearest the target) and push together at "
                           "push_in_min (10-45; aircraft start cold, so allow 10+ min), or earlier once every "
                           "flight is holding when push_when_ready. Then add flights with package= on "
                           "launch_capability / launch_mission (air only).",
         obj({"package": _s("string"), "target_zone": _s("string"), "push_in_min": _s("number"),
              "ip_nm": _s("number"), "from_zone": _s("string"), "push_when_ready": _s("boolean")},
             ["package", "target_zone"])),
        ("list_packages", "Your packages: push time, IP, and each flight's state (waiting, holding, released, "
                          "direct = arrived after the push or past the IP, aborted, lost).", obj({})),
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
        ("cancel_orders", "Cancel delayed orders from earlier cycles that have not run yet "
                          "(get_overview -> delayedOrdersPending), e.g. when the plan changed.",
         obj({"order_ids": {"type": "array", "items": _s("string")}}, ["order_ids"])),
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
            ("list_operations", "RED operations: prices, ground templates you can deploy, zones with a free "
                                "upgrade slot and the templates they take, fire systems (range, salvo, reload), "
                                "helicopter origins, raid guns, ambush teams, jammer, AWACS, and what is in "
                                "progress.", obj({})),
            ("deploy_forces", "Place an extra ground group (armor, AAA, SHORAD, SAM, infantry, artillery) in one of "
                              "your zones. It fights but does not count as a zone defender for capture.",
             obj({"zone": _s("string"), "template": _s("string")}, ["zone", "template"])),
            ("upgrade_zone", "Fill a zone's free upgrade slot with an exact template. It becomes a permanent "
                             "defender of the zone (rebuilt by supply like other defenders).",
             obj({"zone": _s("string"), "template": _s("string")}, ["zone", "template"])),
            ("fire_mission", "Long-range strike: a launcher battery sets up in your origin zone and fires at an "
                             "enemy zone's units. The battery stays as a target for a while; each system then "
                             "reloads.",
             obj({"system": _s("string"), "origin": _s("string"), "target_zone": _s("string"),
                  "delay_min": delay}, ["system", "origin", "target_zone"])),
            ("move_awacs", "Move the RED AWACS orbit over one of your zones (race track heading_deg, leg_nm).",
             obj({"zone": _s("string"), "heading_deg": _s("number"), "leg_nm": _s("number")}, ["zone"])),
            ("supply_airlift", "Add supply units to one of your zones at once (the dispatcher then uses them).",
             obj({"zone": _s("string")}, ["zone"])),
            ("heli_raid", "A Mi-8 carries an artillery piece from a helicopter origin, lands it within range of an "
                          "enemy zone, the gun fires; the helicopter flies home. Can be shot down on the way.",
             obj({"origin": _s("string"), "target_zone": _s("string"), "gun": _s("string"),
                  "delay_min": delay}, ["origin", "target_zone"])),
            ("air_assault", "A Mi-8 lands troops in a neutral zone; they capture it if they survive.",
             obj({"origin": _s("string"), "target_zone": _s("string"), "delay_min": delay},
                 ["origin", "target_zone"])),
            ("ambush", "A Mi-8 drops a MANPADS or AAA team on the line from from_zone to toward_zone, at "
                       "fraction (0.1-0.9) of the way. Use it on routes enemy helicopters and CAS fly.",
             obj({"origin": _s("string"), "from_zone": _s("string"), "toward_zone": _s("string"),
                  "fraction": _s("number"), "team": _s("string"), "delay_min": delay},
                 ["origin", "from_zone", "toward_zone"])),
            ("jam", "Send the RED jammer to orbit near an enemy zone: its SAM radars within range hold fire while "
                    "the jammer lives. Time SEAD/strikes to arrive while it is on station.",
             obj({"target_zone": _s("string"), "delay_min": delay}, ["target_zone"])),
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
                for key in NUMERIC_ARGS:
                    if args.get(key) is not None:
                        try:
                            args[key] = float(args[key])
                        except (TypeError, ValueError):
                            raise ValueError(f"{key} must be a number") from None
                result = getattr(tools, name)(**args)
                text = result if isinstance(result, str) else json.dumps(result, separators=(",", ":"))
                send({"jsonrpc": "2.0", "id": mid, "result": {"content": [{"type": "text", "text": text}]}})
            except Exception as exc:  # any bad argument must not end the session
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
    # Claude Code talks UTF-8; Windows pipes would otherwise use the ANSI code page.
    for stream in (sys.stdin, sys.stdout):
        if hasattr(stream, "reconfigure"):
            stream.reconfigure(encoding="utf-8", errors="replace")
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
