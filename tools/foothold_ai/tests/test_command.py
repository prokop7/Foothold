"""Offline tests for command mode: takeover, executor, standing orders,
snapshot, MCP game tools and the agent cycle pipe."""

from __future__ import annotations

import io
import json
import pathlib
import subprocess
import sys
import tempfile
import unittest

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent))

import agent  # noqa: E402
import mcp_server  # noqa: E402
import sidecar  # noqa: E402
from test_foothold_ai import LuaHarness, lua51  # noqa: E402


def lua_list(t):
    return [t[i] for i in range(1, len(t) + 1)] if t is not None else []


@unittest.skipIf(lua51 is None, "lupa not installed")
class CommandLuaTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.saved = pathlib.Path(self.tmp.name)
        self.h = LuaHarness(self.saved)
        self.h.lua.execute((HERE / "command_stub.lua").read_text(encoding="utf-8"))
        self.h.lua.execute("FootholdAIConfig = { wingman = { enabled = false } }")
        self.h.load_script("Foothold_AI_Core.lua")
        self.h.load_script("Foothold_AI_Command.lua")
        self.g = self.h.g
        self.fs = self.g.FS
        self.x = self.g.FootholdAI.command
        self.exchange = self.saved / "Missions" / "Saves" / "FootholdAI"
        self.session = self.g.FootholdAI.bridge.session
        self.seq = 1000

    def tearDown(self):
        self.tmp.cleanup()

    def calls(self, name):
        return [c for c in self.fs.calls.values() if c.name == name]

    def send_orders(self, side, orders):
        self.seq += 1
        sidecar.write_orders(self.exchange, side, {
            "schema": sidecar.ORDERS_SCHEMA, "side": side, "seq": self.seq, "session": self.session,
            "kind": "command", "cycle": 1, "summary": "test", "orders": orders})
        self.h.advance(5)

    def results(self, side):
        return {r.order: (r.status, r.detail) for r in self.x.results[side].values()}

    def snapshot(self, side):
        return json.loads((self.exchange / f"state_{side}_command.json").read_text(encoding="utf-8"))["payload"]

    # -- takeover ---------------------------------------------------------
    def test_director_decisions_are_neutral_for_controlled_sides(self):
        red, blue = self.fs.red, self.fs.blue
        self.assertEqual(red._startOperation(red), False)
        self.assertIsNone(red._reconcileRoutineCaps(red))
        self.assertEqual(red.requestReactiveCap(red), False)
        self.assertIsNone(blue._blueAdoptActiveAttackMission(blue))
        self.assertEqual(len([c for c in self.fs.calls.values() if str(c.name).startswith("original:")]), 0)
        self.assertEqual(red._executeStrategicBudgetCandidate(red, self.h.lua.table(action="upgrade", cost=1), 0), False)
        self.assertEqual(self.fs.bc._redReactiveTick(self.fs.bc, None, 100), 130)
        self.assertEqual(len(self.calls("redReactiveTick")), 0)
        self.g.evc.chooseAndStart(self.g.evc)
        self.assertEqual(len(self.calls("evcRandom")), 0)

    def test_spawn_gate(self):
        red = self.fs.red
        t = self.h.lua.table
        self.assertFalse(red.allowsGroupSpawn(red, t(name="g1", side=1, mission="attack", state="inhangar")))
        self.assertTrue(red.allowsGroupSpawn(red, t(name="g2", side=1, mission="supply", state="inhangar")))
        self.assertTrue(red.allowsGroupSpawn(red, t(name="g3", side=1, mission="attack", forceSpawn=True)))
        self.assertTrue(red.allowsGroupSpawn(red, t(name="g4", side=1, mission="attack", state="inair")))
        self.assertTrue(red.allowsGroupSpawn(red, t(name="g5", side=1, mission="attack", _pendingInAirRestore=True)))
        self.x.authorized["g6"] = t(at=0, orderId="o1", side=1)
        self.assertTrue(red.allowsGroupSpawn(red, t(name="g6", side=1, mission="attack", state="preparing")))

    # -- snapshot -----------------------------------------------------------
    def test_snapshot_contents(self):
        self.h.advance(80)
        red = self.snapshot("red")
        caps = {c["id"]: c for c in red["capabilities"]}
        self.assertTrue(caps["red-cas-bluefront"]["available"])
        self.assertFalse(caps["red-cas-blocked"]["available"])
        self.assertEqual(caps["red-cas-blocked"]["reason"], "no-warehouse-stock")
        self.assertNotIn("blue-cap-base", caps)
        self.assertIn("CAS", [r["role"] for r in red["freeform"]["roles"]])
        self.assertEqual([o["zone"] for o in red["freeform"]["airOrigins"]], ["Red Base"])
        self.assertIn("upgrade", [i["item"] for i in red["purchases"]["items"]])
        self.assertNotIn("Red Full", red["purchases"]["upgradeZones"])
        self.assertEqual(red["scriptedEvents"], [{"event": "scuds", "available": True},
                                                  {"event": "helohunt", "available": False}])
        self.assertEqual(red["detectedEnemyAir"][0]["nearZone"], "Red Front")
        self.assertEqual(red["economy"]["credits"], 5000)
        blue = self.snapshot("blue")
        self.assertIn("playerTasking", blue)
        self.assertEqual(blue["detectedEnemyAir"], [])

    # -- executor -----------------------------------------------------------
    def test_launch_capability_and_lifecycle(self):
        self.send_orders("red", [{"id": "a1", "type": "launch_capability", "capability": "red-cas-bluefront"}])
        self.assertEqual(self.results("red")["a1"][0], "executed")
        self.assertEqual(len(self.calls("authorize")), 1)
        gc = self.fs.bc.directorInstanceByCapabilityId["red-cas-bluefront"]
        self.assertEqual(gc.state, "preparing")
        red = self.fs.red
        self.assertTrue(red.allowsGroupSpawn(red, gc))
        gc.state = "inair"
        red.onGroupStateChanged(red, gc, "preparing", "inair", False, True)
        gc.state = "dead"
        red.onGroupStateChanged(red, gc, "inair", "dead", True, False)
        self.assertIsNone(self.x.authorized[gc.name])
        ended = [e for e in self.x.events.red.values() if e.kind == "mission_ended"]
        self.assertEqual(ended[0].outcome, "lost")

    def test_launch_rejections_and_retarget(self):
        self.send_orders("red", [
            {"id": "b1", "type": "launch_capability", "capability": "red-cas-blocked"},
            {"id": "b2", "type": "launch_capability", "capability": "red-arty-bluefront", "targetZone": "Neutral Hill"},
            {"id": "b3", "type": "launch_capability", "capability": "blue-cap-base"},
            {"id": "b4", "type": "launch_capability", "capability": "red-cap-front", "targetZone": "Neutral Hill"},
        ])
        r = self.results("red")
        self.assertEqual(r["b1"], ("rejected", "not eligible: no-warehouse-stock"))
        self.assertIn("cannot be sent to another target", r["b2"][1])
        self.assertEqual(r["b3"], ("rejected", "origin zone not held"))
        self.assertEqual(r["b4"][0], "executed")
        self.assertEqual(self.fs.bc.directorInstanceByCapabilityId["red-cap-front"].targetzone, "Neutral Hill")

    def test_denied_launch_is_cleaned_up(self):
        self.send_orders("red", [{"id": "d1", "type": "launch_capability", "capability": "red-cas-bluefront"}])
        gc = self.fs.bc.directorInstanceByCapabilityId["red-cas-bluefront"]
        self.assertTrue(self.fs.red.onManagedSpawnDenied(self.fs.red, gc, "runway-blocked"))
        self.assertIsNone(self.x.authorized[gc.name])
        self.assertEqual(len(self.calls("dispose")), 1)
        self.assertEqual(len(self.calls("originalDenied")), 0)

    def test_freeform_mission_charges_and_persists(self):
        self.send_orders("red", [
            {"id": "f1", "type": "launch_mission", "origin": "Red Base", "role": "SEAD", "targetZone": "Blue Front"},
            {"id": "f2", "type": "launch_mission", "origin": "Red Front", "role": "CAS", "targetZone": "Blue Front"},
        ])
        r = self.results("red")
        self.assertEqual(r["f1"][0], "executed")
        self.assertIn("cost 500", r["f1"][1])
        self.assertEqual(self.fs.bc.accounts[1], 4500)
        cap = self.fs.bc.directorCapabilitiesById["FAI-red-Red_Base-Blue_Front-SEAD"]
        self.assertEqual(cap.MissionType, "SEAD")
        self.assertEqual(cap.Altitude, 28000)
        self.assertTrue(list(self.exchange.glob("freeform_*.lua")))
        self.assertEqual(r["f2"], ("rejected", "Red Front cannot launch aircraft"))

    def test_freeform_insufficient_credits(self):
        self.fs.bc.accounts[1] = 100
        self.send_orders("red", [{"id": "f3", "type": "launch_mission", "origin": "Red Base", "role": "CAS",
                                  "targetZone": "Blue Front"}])
        self.assertIn("not enough credits", self.results("red")["f3"][1])

    def test_purchase_upgrade_with_zone_and_category(self):
        self.send_orders("red", [
            {"id": "p1", "type": "purchase", "item": "upgrade", "zone": "Red Front", "category": "shorad"},
        ])
        self.assertEqual(self.results("red")["p1"][0], "executed")
        self.assertEqual(self.fs.lastUpgradeSlot, "Red SAM SHORAD SA-8")
        self.assertEqual(self.fs.bc.accounts[1], 4000)
        self.assertEqual(len(self.calls("originalSelectZoneUpgradeTarget")), 0)
        self.send_orders("red", [{"id": "p2", "type": "purchase", "item": "upgrade", "zone": "Red Front",
                                  "category": "sam"}])
        self.assertIn("no sam upgrade available", self.results("red")["p2"][1])
        self.send_orders("blue", [{"id": "p3", "type": "purchase", "item": "upgrade", "zone": "Blue Front"}])
        self.assertIn("RED only", self.results("blue")["p3"][1])

    def test_supply_priority_and_run(self):
        self.send_orders("red", [
            {"id": "s1", "type": "supply_priority", "zone": "Red Front", "priority": "high"},
            {"id": "s2", "type": "supply_priority", "zone": "Neutral Hill", "priority": "none"},
            {"id": "s3", "type": "supply_run", "capability": "red-supply-front"},
        ])
        bc = self.fs.bc
        high = bc._regularSupplyTargetPriority(bc, 1, self.fs.bc.byName["Red Front"])
        self.assertEqual(high.priority, 500)
        starved = bc._regularSupplyTargetPriority(bc, 1, self.fs.bc.byName["Neutral Hill"])
        self.assertEqual(starved.unfilled, 0)
        blue_view = bc._regularSupplyTargetPriority(bc, 2, self.fs.bc.byName["Red Front"])
        self.assertEqual(blue_view.priority, 100)
        self.assertEqual(self.results("red")["s3"][0], "executed")

    def test_player_tasking(self):
        blue = self.fs.blue
        cands = self.h.lua.table_from([self.h.lua.table(zoneName="Red Front"), self.h.lua.table(zoneName="Red Base")])
        self.assertIsNone(blue.selectMissionTarget(blue, "CAS", cands, None))
        self.assertEqual(lua_list(self.x.taskCandidates["CAS"]), ["Red Front", "Red Base"])
        self.send_orders("blue", [{"id": "t1", "type": "player_tasks", "role": "CAS", "zones": ["Red Base", "Red Front"]}])
        self.assertEqual(blue.selectMissionTarget(blue, "CAS", cands, None).zoneName, "Red Base")
        self.assertIsNone(blue.selectMissionTarget(blue, "SEAD", cands, None))
        self.assertEqual(len(self.calls("originalSelectMissionTarget")), 0)

    def test_scripted_event_and_hq_message(self):
        self.send_orders("red", [{"id": "e1", "type": "trigger_event", "event": "scuds"},
                                 {"id": "e2", "type": "trigger_event", "event": "helohunt"},
                                 {"id": "e3", "type": "trigger_event", "event": "StrikePort"}])
        r = self.results("red")
        self.assertEqual(r["e1"][0], "executed")
        self.assertEqual(r["e2"], ("rejected", "event cannot run now"))
        self.assertEqual(r["e3"], ("rejected", "unknown event"))
        self.send_orders("blue", [{"id": "m1", "type": "hq_message", "text": "SEAD package at 14:30"}])
        self.assertIn("HQ: SEAD package at 14:30", [t.text for t in self.g.STUB.coalitionTexts.values()])

    def test_delayed_order(self):
        self.send_orders("red", [{"id": "w1", "type": "launch_capability", "capability": "red-cas-bluefront",
                                  "delaySec": 120}])
        self.assertEqual(self.results("red")["w1"][0], "scheduled")
        self.assertEqual(len(self.calls("authorize")), 0)
        self.h.advance(121)
        self.assertEqual(self.results("red")["w1"][0], "executed")

    # -- standing orders -----------------------------------------------------
    def test_standing_scramble_with_cooldown_and_max_active(self):
        self.send_orders("red", [{"id": "so", "type": "standing_orders", "rules": [
            {"id": "scramble-front", "trigger": "enemy_air_near", "zone": "Red Front", "radiusNm": 10,
             "cooldownSec": 600, "maxActive": 1,
             "action": {"type": "launch_capability", "capability": "red-cap-front"}},
            {"id": "bad", "trigger": "teleport", "zone": "Red Front", "action": {"type": "launch_capability"}},
        ]}])
        self.assertIn("1 standing orders active", self.results("red")["so"][1])
        self.assertIn("bad: bad trigger", self.results("red")["so"][1])
        self.h.advance(11)
        fired = [r for r in self.x.results.red.values() if "scramble-front" in str(r.detail)]
        self.assertEqual(len(fired), 1)
        self.assertEqual(fired[0].status, "executed")
        self.assertTrue(self.x.eventPending.red)
        rule = self.x.standing.red[1]
        self.h.advance(60)
        self.assertEqual(rule.fired, 1)  # cooldown and maxActive hold it
        gc = self.fs.bc.directorInstanceByCapabilityId["red-cap-front"]
        gc.state = "dead"
        self.fs.red.onGroupStateChanged(self.fs.red, gc, "inair", "dead", True, False)
        self.h.advance(600)
        self.assertEqual(rule.fired, 2)  # cooldown over, previous scramble ended

    def test_standing_zone_lost_counterattack(self):
        self.send_orders("red", [{"id": "so", "type": "standing_orders", "rules": [
            {"id": "retake", "trigger": "zone_lost", "zone": "*",
             "action": {"type": "launch_mission", "origin": "Red Base", "role": "CAS", "targetZone": "$zone"}},
        ]}])
        self.g.Director.recordZoneOwnershipChange(self.g.Director, "Red Front", 1, 0)
        fired = [r for r in self.x.results.red.values() if "retake" in str(r.detail)]
        self.assertEqual(fired[0].status, "executed")
        self.assertIsNotNone(self.fs.bc.directorCapabilitiesById["FAI-red-Red_Base-Red_Front-CAS"])

    def test_standing_zone_attacked(self):
        self.send_orders("red", [{"id": "so", "type": "standing_orders", "rules": [
            {"id": "defend", "trigger": "zone_attacked", "zone": "Red Front",
             "action": {"type": "launch_capability", "capability": "red-cap-front"}},
        ]}])
        self.fs.bc.reportAIENAirSupportAttack(self.fs.bc, self.fs.bc.byName["Red Front"], 1, "AH-64D")
        fired = [r for r in self.x.results.red.values() if "defend" in str(r.detail)]
        self.assertEqual(fired[0].status, "executed")
        self.assertEqual(len(self.calls("original:considerAIENAirSupport")), 0)

    # -- request cycle ----------------------------------------------------------
    def test_request_cycle_and_event_trigger(self):
        self.h.advance(80)
        first = json.loads((self.exchange / "state_red_command.json").read_text())["seq"]
        self.send_orders("red", [])
        self.g.Director.recordZoneOwnershipChange(self.g.Director, "Neutral Hill", 0, 2)
        self.h.advance(100)
        st = json.loads((self.exchange / "state_red_command.json").read_text())
        self.assertGreater(st["seq"], first)
        self.assertEqual(st["payload"]["reason"], "event")
        self.assertEqual(st["payload"]["events"][0]["kind"], "zone_changed")


class FakeAgentClaude:
    """Plays Claude by calling the real MCP server over stdio with a fixed script."""

    def __init__(self, script):
        self.script = script
        self.calls = []

    def run_agent(self, prompt, system_prompt_file, mcp_config, allowed, effort, timeout):
        self.calls.append({"prompt": prompt, "system": system_prompt_file, "allowed": allowed, "effort": effort})
        server = json.loads(pathlib.Path(mcp_config).read_text())["mcpServers"]["foothold"]
        proc = subprocess.Popen([server["command"], *server["args"]], stdin=subprocess.PIPE,
                                stdout=subprocess.PIPE, text=True)
        msgs = [{"jsonrpc": "2.0", "id": 0, "method": "initialize", "params": {"protocolVersion": "2025-06-18"}},
                {"jsonrpc": "2.0", "method": "notifications/initialized"},
                {"jsonrpc": "2.0", "id": 1, "method": "tools/list"}]
        for i, (name, args) in enumerate(self.script):
            msgs.append({"jsonrpc": "2.0", "id": 10 + i, "method": "tools/call",
                         "params": {"name": name, "arguments": args}})
        out, _ = proc.communicate("\n".join(json.dumps(m) for m in msgs) + "\n", timeout=30)
        self.responses = [json.loads(line) for line in out.splitlines() if line.strip()]
        return {"is_error": False, "subtype": "success"}


def sample_state(side="red"):
    return {"schema": "footholdai.state.v1", "side": side, "kind": "command", "session": "s1", "seq": 3,
            "payload": {
                "side": side, "reason": "start", "missionClockMin": 600,
                "campaign": {"theatre": "PersianGulf", "saveFile": "pg.lua"},
                "economy": {"credits": 1600, "incomePerMinute": 30},
                "zones": [
                    {"name": "Red Base", "side": "red", "xKm": 0, "zKm": 0, "neighbors": ["Red Front"], "groups": 5},
                    {"name": "Red Front", "side": "red", "xKm": 20, "zKm": 0, "frontline": True,
                     "neighbors": ["Red Base", "Blue Front"], "groups": 4},
                    {"name": "Blue Front", "side": "blue", "xKm": 40, "zKm": 0, "frontline": True,
                     "neighbors": ["Red Front"], "groups": 3},
                ],
                "capabilities": [
                    {"id": "cas1", "origin": "Red Base", "target": "Blue Front", "role": "CAS", "mission": "attack",
                     "domain": "air", "available": True},
                    {"id": "arty1", "origin": "Red Front", "target": "Blue Front", "role": "ARTY",
                     "mission": "attack", "domain": "surface", "available": True},
                    {"id": "cap1", "origin": "Red Base", "target": "Red Front", "role": "CAP", "mission": "patrol",
                     "domain": "air", "available": False, "reason": "no-aircraft"},
                    {"id": "sup1", "origin": "Red Base", "target": "Red Front", "mission": "supply", "domain": "air"},
                ],
                "freeform": {"roles": [{"role": "CAS", "price": 1000, "domain": "air"},
                                       {"role": "SEAD", "price": 500, "domain": "air"}],
                             "airOrigins": [{"zone": "Red Base", "planes": True}]},
                "purchases": {"items": [{"item": "upgrade", "cost": 1000}], "upgradeZones": ["Red Front"]},
                "scriptedEvents": [{"event": "scuds", "available": True}],
                "missions": [], "detectedEnemyAir": [], "events": [], "orderResults": [], "standingOrders": [],
            }}


class McpToolsTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.out = str(pathlib.Path(self.tmp.name) / "orders.json")
        self.t = mcp_server.GameTools(sample_state(), self.out, {"notes": "hold the line"})

    def tearDown(self):
        self.tmp.cleanup()

    def test_overview_includes_notes_and_counts(self):
        o = self.t.get_overview()
        self.assertEqual(o["yourNotesFromLastCycle"], "hold the line")
        self.assertEqual(o["capabilitiesAvailable"], 2)
        self.assertEqual(o["enemyFrontline"], ["Blue Front"])

    def test_capability_validation(self):
        with self.assertRaisesRegex(ValueError, "unavailable: no-aircraft"):
            self.t.launch_capability("cap1")
        with self.assertRaisesRegex(ValueError, "cannot be sent to another target"):
            self.t.launch_capability("arty1", target_zone="Red Base")
        with self.assertRaisesRegex(ValueError, "use order_supply_run"):
            self.t.launch_capability("sup1")
        msg = self.t.launch_capability("cas1", delay_min=5)
        self.assertIn("in 5 min", msg)
        self.assertIn("about", msg)
        with self.assertRaisesRegex(ValueError, "already ordered"):
            self.t.launch_capability("cas1")
        saved = json.loads(pathlib.Path(self.out).read_text())
        self.assertEqual(saved["orders"][0], {"type": "launch_capability", "capability": "cas1",
                                              "delaySec": 300, "id": "c1"})

    def test_freeform_credit_budget(self):
        self.t.launch_mission("Red Base", "CAS", "Blue Front")
        self.t.launch_mission("Red Base", "SEAD", "Blue Front")
        with self.assertRaisesRegex(ValueError, "not enough credits"):
            self.t.launch_mission("Red Base", "SEAD", "Blue Front")
        with self.assertRaisesRegex(ValueError, "cannot launch aircraft"):
            self.t.launch_mission("Red Front", "CAS", "Blue Front")

    def test_purchase_and_standing_orders(self):
        with self.assertRaisesRegex(ValueError, "upgrade zone must be"):
            self.t.purchase("upgrade", zone="Red Base")
        self.t.purchase("upgrade", zone="Red Front", category="shorad")
        self.t.set_standing_orders([{"id": "s", "trigger": "enemy_air_near", "zone": "Red Front", "radius_nm": 30,
                                     "cooldown_min": 5, "action": {"type": "launch_mission", "origin": "Red Base",
                                                                   "role": "SEAD"}}])
        rule = self.t.orders[-1]["rules"][0]
        self.assertEqual(rule["cooldownSec"], 300)
        self.assertEqual(rule["action"]["targetZone"], "$zone")
        with self.assertRaisesRegex(ValueError, "unknown zone"):
            self.t.set_standing_orders([{"id": "x", "trigger": "zone_lost", "zone": "Nowhere",
                                         "action": {"type": "launch_capability", "capability": "cas1"}}])

    def test_jsonrpc_session(self):
        lines = [{"jsonrpc": "2.0", "id": 0, "method": "initialize", "params": {"protocolVersion": "2025-06-18"}},
                 {"jsonrpc": "2.0", "id": 1, "method": "tools/list"},
                 {"jsonrpc": "2.0", "id": 2, "method": "tools/call",
                  "params": {"name": "launch_capability", "arguments": {"capability": "nope"}}},
                 {"jsonrpc": "2.0", "id": 3, "method": "tools/call",
                  "params": {"name": "finish_cycle", "arguments": {"summary": "done"}}}]
        out = io.StringIO()
        mcp_server.serve(self.t, io.StringIO("\n".join(json.dumps(m) for m in lines)), out)
        replies = [json.loads(l) for l in out.getvalue().splitlines()]
        self.assertEqual(replies[0]["result"]["protocolVersion"], "2025-06-18")
        names = {t["name"] for t in replies[1]["result"]["tools"]}
        self.assertIn("purchase", names)
        self.assertNotIn("set_player_tasks", names)
        self.assertTrue(replies[2]["result"]["isError"])
        self.assertIn("Stop now", replies[3]["result"]["content"][0]["text"])


class AgentCycleTest(unittest.TestCase):
    def test_cycle_runs_tools_and_builds_orders(self):
        with tempfile.TemporaryDirectory() as tmp:
            exchange = pathlib.Path(tmp)
            claude = FakeAgentClaude([
                ("get_overview", {}),
                ("launch_capability", {"capability": "cas1", "delay_min": 2}),
                ("launch_capability", {"capability": "cap1"}),
                ("finish_cycle", {"summary": "CAS on Blue Front", "notes": "check CAS result"}),
            ])
            orders = agent.run_cycle(claude, exchange, "red", sample_state(), "medium", 60)
            self.assertEqual(orders["kind"], "command")
            self.assertEqual(orders["cycle"], 1)
            self.assertEqual([o["id"] for o in orders["orders"]], ["r1-c1"])
            self.assertEqual(orders["orders"][0]["delaySec"], 120)
            self.assertTrue(claude.responses[3]["result"].get("isError") is None)
            self.assertTrue(claude.responses[4]["result"]["isError"])
            self.assertIn("mcp__foothold__purchase", claude.calls[0]["allowed"])
            memory = json.loads((exchange / "memory_PersianGulf_pg.lua_red.json").read_text())
            self.assertEqual(memory["notes"], "check CAS result")
            self.assertIn(memory["personality"], agent.PERSONALITIES["red"])
            again = agent.run_cycle(FakeAgentClaude([("get_overview", {})]), exchange, "red", sample_state(), "medium", 60)
            self.assertEqual(again["cycle"], 2)
            self.assertEqual(again["orders"], [])


@unittest.skipIf(lua51 is None, "lupa not installed")
class EndToEndTest(unittest.TestCase):
    def test_snapshot_to_claude_tools_to_mission(self):
        with tempfile.TemporaryDirectory() as tmp:
            saved = pathlib.Path(tmp)
            h = LuaHarness(saved)
            h.lua.execute((HERE / "command_stub.lua").read_text(encoding="utf-8"))
            h.lua.execute("FootholdAIConfig = { wingman = { enabled = false } }")
            h.load_script("Foothold_AI_Core.lua")
            h.load_script("Foothold_AI_Command.lua")
            h.advance(80)
            exchange = saved / "Missions" / "Saves" / "FootholdAI"
            bridge = sidecar.Bridge(exchange, None)
            bridge.claude = FakeAgentClaude([
                ("launch_capability", {"capability": "red-cas-bluefront"}),
                ("purchase", {"item": "upgrade", "zone": "Red Front", "category": "armor"}),
                ("finish_cycle", {"summary": "push"}),
            ])
            state = bridge.read_state("red", "command")
            bridge.handle("red", state)
            h.advance(5)
            res = {r.order: r.status for r in h.g.FootholdAI.command.results.red.values()}
            self.assertEqual(res, {"r1-c1": "executed", "r1-c2": "executed"})
            bridge.pool.shutdown()


if __name__ == "__main__":
    unittest.main()
