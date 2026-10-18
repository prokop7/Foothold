"""Regression tests for the blind-review findings (one or more per finding)."""

from __future__ import annotations

import io
import json
import os
import pathlib
import sys
import tempfile
import time
import unittest
from unittest import mock

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent))

import mcp_server  # noqa: E402
import sidecar  # noqa: E402
from test_command import sample_state  # noqa: E402
from test_foothold_ai import lua51  # noqa: E402
from test_ops import OpsHarness, OpsLuaTest, ops_state  # noqa: E402


@unittest.skipIf(lua51 is None, "lupa not installed")
class CommandFixesTest(OpsHarness, unittest.TestCase):
    def send_orders(self, side, orders, ack):
        exchange = self.saved / "Missions" / "Saves" / "FootholdAI"
        self.seq = getattr(self, "seq", 1000) + 1
        sidecar.write_orders(exchange, side, {
            "schema": sidecar.ORDERS_SCHEMA, "side": side, "seq": self.seq,
            "session": self.g.FootholdAI.bridge.session, "kind": "command", "cycle": 1, "summary": "t",
            "orders": orders, "ackSeq": ack})
        self.h.advance(5)

    def results(self, side="red"):
        return {r.order: (r.status, r.detail) for r in self.x.results[side].values()}

    def launch_freeform(self, oid="o1"):
        ok, detail = self.order(1, id=oid, type="launch_mission", origin="Red Base", role="CAS",
                                targetZone="Blue Front")
        self.assertTrue(ok, detail)
        return self.fs.bc.directorInstanceByCapabilityId["FAI-red-Red_Base-Blue_Front-CAS"]

    def test_orders_must_answer_the_awaited_snapshot(self):
        self.x.awaiting.red = 50
        self.send_orders("red", [{"id": "x1", "type": "hq_message", "text": "late"}], ack=49)
        self.assertNotIn("x1", self.results())
        self.send_orders("red", [{"id": "x2", "type": "supply_priority", "zone": "Red Front",
                                  "priority": "high"}], ack=50)
        self.assertEqual(self.results()["x2"][0], "executed")
        # a replay of the same answer is ignored too
        self.send_orders("red", [{"id": "x3", "type": "supply_priority", "zone": "Red Front",
                                  "priority": "low"}], ack=50)
        self.assertNotIn("x3", self.results())

    def test_delayed_orders_can_be_cancelled(self):
        self.x.awaiting.red = 60
        self.send_orders("red", [{"id": "r1-c1", "type": "supply_airlift", "zone": "Red Front", "delaySec": 600}],
                         ack=60)
        self.assertEqual(self.results()["r1-c1"][0], "scheduled")
        ok, detail = self.order(1, type="cancel_orders", ids=self.lua.table_from(["r1-c1", "nope"]))
        self.assertTrue(ok)
        self.assertIn("not pending: nope", detail)
        self.h.advance(700)
        self.assertEqual(len(self.calls("supplyStock")), 0)

    def test_freeform_relaunch_costs_full_price(self):
        start = self.credits()
        gc = self.launch_freeform()
        self.assertEqual(self.credits(), start - 1000)
        gc.state = "inhangar"
        self.x.authorized[gc.name] = None
        ok, detail = self.order(1, id="o2", type="launch_capability", capability="FAI-red-Red_Base-Blue_Front-CAS")
        self.assertTrue(ok, detail)
        self.assertIn("fee 1000", detail)
        self.assertEqual(self.credits(), start - 2000)

    def test_refund_when_launch_is_denied(self):
        start = self.credits()
        gc = self.launch_freeform()
        self.fs.red.onManagedSpawnDenied(self.fs.red, gc, "blue-player-near-origin")
        self.assertEqual(self.credits(), start)
        self.assertIn("refund: launch denied", self.ledger()[0][1])

    def test_refund_when_never_launched(self):
        start = self.credits()
        self.launch_freeform()
        self.h.advance(1300)
        self.assertEqual(self.credits(), start)

    def test_no_refund_after_a_real_sortie(self):
        start = self.credits()
        gc = self.launch_freeform()
        gc.state = "inair"
        self.fs.red.onGroupStateChanged(self.fs.red, gc, "preparing", "inair", False, True)
        gc.state = "dead"
        self.fs.red.onGroupStateChanged(self.fs.red, gc, "inair", "dead", True, False)
        self.assertEqual(self.credits(), start - 1000)

    def test_missions_are_keyed_per_side(self):
        self.launch_freeform("same")
        self.assertIsNotNone(self.x.missions["red/same"])
        self.assertIsNone(self.x.missions["same"])

    def test_reactions_return_numbers_and_saved_operation_is_ended(self):
        red = self.fs.red
        self.assertEqual(red.requestReaction(red), 0)
        self.assertEqual(red.requestReactiveCap(red), 0)
        red.operation = self.lua.table_from({"targetZone": "Blue Front"})
        red._updateOperation(red, 100)
        self.assertEqual(self.calls("finishOperation")[0].args[1], "aborted")
        self.assertIsNone(red.operation)
        self.assertEqual(len(self.calls("original:_updateOperation")), 0)

    def test_capture_reward_uses_mission_table(self):
        self.fs.bc.rewards["Zone capture"] = 300
        start = self.credits()
        self.g.Director.recordZoneOwnershipChange(self.g.Director, "Neutral Hill", 0, 1)
        self.assertEqual(self.credits(), start + 300)

    def test_unpaid_kills_settle_when_aircraft_vanishes(self):
        start = self.credits()
        jet = self.unit("red jet", 1, 0, 0)
        self.fire(28, jet, self.unit("blue jet", 2, 0, 100))
        jet.alive = False   # removed without a landing or loss event
        self.h.advance(15)
        self.assertIsNone(self.x.unpaidKills["red jet-1"])
        self.assertEqual(self.credits(), start + 12)   # 25 % of 50, floored

    def test_trigger_event_costs_and_cools_down(self):
        start = self.credits()
        ok, detail = self.order(1, type="trigger_event", event="scuds")
        self.assertTrue(ok, detail)
        self.assertEqual(self.credits(), start - 1000)
        ok, detail = self.order(1, type="trigger_event", event="scuds")
        self.assertFalse(ok)
        self.assertIn("possible again in 60 min", detail)

    def test_mass_attack_cooldown(self):
        self.fs.shop.redmassattack.cost = 100
        self.assertTrue(self.order(1, type="purchase", item="mass_attack",
                                   targets=self.lua.table_from(["Blue Front"]))[0])
        self.fs.red.strategicSpendCooldownUntil = 0
        ok, detail = self.order(1, type="purchase", item="mass_attack", targets=self.lua.table_from(["Blue Front"]))
        self.assertFalse(ok)
        self.assertIn("mass attack possible again", detail)

    def test_standing_orders_over_limit_are_reported(self):
        self.g.FootholdAI.config.command.maxStandingOrders = 1
        rules = self.lua.eval("""{
            { id = 'a', trigger = 'zone_lost', zone = '*', action = { type = 'launch_capability', capability = 'x' } },
            { id = 'b', trigger = 'zone_lost', zone = '*', action = { type = 'launch_capability', capability = 'x' } } }""")
        ok, detail = self.x.setStandingOrders("red", rules)
        self.assertIn("b: over the limit of 1 rules", detail)

    def test_zone_attacked_events_are_collapsed(self):
        zone = self.fs.bc.byName["Red Front"]
        for _ in range(5):
            self.fs.bc.reportAIENAirSupportAttack(self.fs.bc, zone, "air", "A-10C")
        attacks = [e for e in self.x.events.red.values() if e.kind == "zone_attacked"]
        self.assertEqual(len(attacks), 1)

    def test_legacy_zone_groups_are_offered_and_launchable(self):
        self.lua.execute("""
            table.insert(FS.bc.byName['Red Front'].groups, { name = 'foxtrot-artillery-fire-at-golf', side = 1,
                mission = 'attack', MissionType = 'ARTY', type = 'surface', state = 'inhangar',
                targetzone = 'Blue Front', zoneCommander = FS.bc.byName['Red Front'] })
        """)
        self.x.request("red", "cycle")
        self.h.advance(2)
        st = json.loads((self.saved / "Missions" / "Saves" / "FootholdAI" / "state_red_command.json")
                        .read_text(encoding="utf-8"))["payload"]
        legacy = [c for c in st["capabilities"] if c.get("legacy")]
        self.assertEqual(legacy[0]["id"], "foxtrot-artillery-fire-at-golf")
        self.assertTrue(legacy[0]["available"])
        ok, detail = self.order(1, id="l1", type="launch_capability", capability="foxtrot-artillery-fire-at-golf")
        self.assertTrue(ok, detail)
        self.assertEqual(self.calls("fastForward")[0].args[1], "foxtrot-artillery-fire-at-golf")

    def test_commanded_sides_are_polled(self):
        sides = list(self.g.FootholdAI.config.bridge.sides.values())
        self.assertIn("red", sides)
        self.assertIn("blue", sides)

    def test_bytecode_order_files_are_rejected(self):
        exchange = self.saved / "Missions" / "Saves" / "FootholdAI"
        (exchange / "orders_red_command.lua").write_bytes(b"\x1bLua\x51\x00garbage")
        self.h.advance(5)
        self.assertTrue(any("not a text data file" in line for line in self.h.logs()))


@unittest.skipIf(lua51 is None, "lupa not installed")
class OpsFixesTest(OpsHarness, unittest.TestCase):
    land_flight = OpsLuaTest.land_flight
    add_jammer_template = OpsLuaTest.add_jammer_template

    def test_jam_ending_normally_restores_radars(self):
        self.add_jammer_template()
        self.assertTrue(self.order(1, type="jam", targetZone="Blue Front")[0])
        self.h.advance(1)
        jammer = next(iter(self.x.ops.flights.keys()))
        orbit = self.g.STUB.groups[jammer].controller.task.params.route.points[2].task.params.tasks[1]
        self.g.STUB.groups[jammer].units[1].p.x = orbit.params.point.x
        self.h.advance(10)
        near = self.g.STUB.units["near-sr"].controller
        self.assertEqual(near.options[0], 4)
        self.h.advance(1800)   # time on station is over, the jammer heads home
        self.assertEqual((near.options[0], near.options[9]), (2, 2))

    def test_long_range_sam_jammed_from_further_out(self):
        self.add_jammer_template()
        self.lua.execute("""
            FS.bc.byName['Blue Front'].built = { 'blue patriot' }
            STUB.makeGroup('blue patriot', 2, 2, { { name = 'pat-str', type = 'Patriot str', air = false,
                attrs = { ['SAM SR'] = true }, p = { x = 40000, y = 0, z = 0 } } })
        """)
        self.order(1, type="jam", targetZone="Blue Front")
        self.h.advance(1)
        jammer = next(iter(self.x.ops.flights.keys()))
        self.g.STUB.groups[jammer].units[1].p.x = 40000 - 55 * 1852   # outside 40 nm, inside 60 nm
        self.h.advance(10)
        self.assertEqual(self.g.STUB.units["pat-str"].controller.options[0], 4)

    def wake_stub(self, zone, wakes=True):
        self.lua.execute(f"""
            local z = FS.bc.byName['{zone}']
            z.suspended, z._idleSuspended = true, true
            z.resume = function(self) if {str(wakes).lower()} then self.suspended, self._idleSuspended = false, false end end
        """)

    def test_fire_mission_wakes_idle_target(self):
        self.wake_stub("Blue Base")
        ok, detail = self.order(1, type="fire_mission", system="scud", origin="Red Base", targetZone="Blue Base")
        self.assertTrue(ok, detail)
        self.h.advance(62)
        self.assertEqual(len(self.calls("fireAtZone")), 1)
        self.assertEqual(self.x.events.red[1].result, "fired")

    def test_fire_mission_refunded_when_target_never_wakes(self):
        self.wake_stub("Blue Base", wakes=False)
        start = self.credits()
        self.order(1, type="fire_mission", system="scud", origin="Red Base", targetZone="Blue Base")
        self.h.advance(200)
        self.assertEqual(len(self.calls("fireAtZone")), 0)
        self.assertEqual(self.credits(), start)

    def test_fire_mission_refunded_when_engine_refuses(self):
        self.lua.execute("FS.fireError = 'No targets found within zone'")
        start = self.credits()
        self.order(1, type="fire_mission", system="scud", origin="Red Base", targetZone="Blue Base")
        self.h.advance(62)
        self.assertEqual(self.credits(), start)
        self.assertIn("refunded", self.x.events.red[1].result)

    def test_fire_mission_minimum_range(self):
        self.g.FootholdAI.config.command.ops.fireSystems.smerch.minKm = 30
        ok, detail = self.order(1, type="fire_mission", system="smerch", origin="Red Front", targetZone="Blue Front")
        self.assertFalse(ok)
        self.assertIn("needs at least 30 km", detail)

    def test_destroyed_deployed_group_does_not_come_back(self):
        self.order(1, type="deploy_forces", zone="Red Front", template="Red Armour Group")
        name = self.x.ops.deployed[1].group
        self.g.STUB.groups[name].destroy(self.g.STUB.groups[name])
        self.h.advance(61)
        saved = next((self.saved / "Missions" / "Saves" / "FootholdAI").glob("ops_*.lua")).read_text()
        self.assertNotIn("Red Armour Group", saved)

    def test_helicopter_timeout_covers_the_flight(self):
        self.order(1, type="heli_raid", origin="Red Base", targetZone="Blue Front")
        f = next(iter(self.x.ops.flights.values()))
        km = abs(f.lz.x) / 1000
        self.assertGreaterEqual(f.timeoutSec, 2 * km * 1000 / (220 / 3.6))
        self.assertGreaterEqual(f.timeoutSec, 2400)

    def test_could_not_land_is_refunded(self):
        start = self.credits()
        self.order(1, type="heli_raid", origin="Red Base", targetZone="Blue Front")
        self.h.advance(200)
        self.land_flight(at=(0, 0))   # back home, never landed at the site
        self.assertEqual(self.credits(), start)
        ended = [e for e in self.x.events.red.values() if e.kind == "operation_ended"]
        self.assertIn("could not land", ended[0].outcome)

    def test_dead_ambush_teams_free_their_slot(self):
        self.g.FootholdAI.config.command.ops.ambushMaxActive = 1
        self.order(1, type="ambush", origin="Red Base", fromZone="Red Front", towardZone="Blue Front")
        self.land_flight()
        team = self.g.STUB.spawns[1].name
        self.land_flight(at=(0, 0))
        self.assertIn("limit", self.order(1, type="ambush", origin="Red Base", fromZone="Red Front",
                                          towardZone="Blue Front")[1])
        self.g.STUB.groups[team].destroy(self.g.STUB.groups[team])
        self.assertTrue(self.order(1, type="ambush", origin="Red Base", fromZone="Red Front",
                                   towardZone="Blue Front")[0])

    def test_awacs_station_dropped_when_zone_lost(self):
        self.g._awacsFG[1] = self.g.STUB.makeGroup("AWACS_RED", 0, 1, self.lua.table_from([self.lua.table_from({
            "name": "aw-1", "type": "E-3A", "p": self.lua.table_from({"x": 0, "y": 9000, "z": 0})})]))
        self.order(1, type="move_awacs", zone="Red Front")
        self.fs.bc.byName["Red Front"].side = 2
        self.g.setAwacsRacetrack(1, self.lua.table_from({"x": 1, "z": 1}), 0, 10, "Red Base")
        self.assertEqual(self.calls("setAwacsRacetrack")[-1].args[2], "Red Base")


class SidecarFixesTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = pathlib.Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def state(self, side="red", seq=5, kind="command"):
        return {"schema": sidecar.STATE_SCHEMA, "side": side, "kind": kind, "session": "s", "seq": seq,
                "payload": {"reason": "cycle"}}

    def test_stale_command_state_is_skipped_at_start(self):
        path = self.dir / "state_red_command.json"
        path.write_text(json.dumps(self.state()), encoding="utf-8")
        old = time.time() - 600
        os.utime(path, (old, old))
        bridge = sidecar.Bridge(self.dir, None)
        self.assertIsNone(bridge.read_state("red", "command"))
        path.write_text(json.dumps(self.state(seq=6)), encoding="utf-8")
        self.assertEqual(bridge.read_state("red", "command")["seq"], 6)
        bridge.pool.shutdown()

    def test_invalid_utf8_does_not_stall(self):
        path = self.dir / "state_red_command.json"
        path.write_bytes(json.dumps(self.state()).replace('"cycle"', '"cy\\u00e9"').encode().replace(
            b"cy\\u00e9", b"cy\xc3"))
        bridge = sidecar.Bridge(self.dir, None)
        self.assertEqual(bridge.read_state("red", "command")["seq"], 5)
        bridge.pool.shutdown()

    def test_write_orders_retries_while_file_is_locked(self):
        real = os.replace
        calls = {"n": 0}

        def flaky(a, b):
            calls["n"] += 1
            if calls["n"] < 3:
                raise PermissionError("in use")
            return real(a, b)

        with mock.patch("sidecar.os.replace", side_effect=flaky):
            sidecar.write_orders(self.dir, "red", {"kind": "command", "orders": []})
        self.assertTrue((self.dir / "orders_red_command.lua").exists())
        self.assertEqual(calls["n"], 3)

    def test_timeout_kills_the_process(self):
        started = time.monotonic()
        with self.assertRaises(TimeoutError):
            sidecar.run_process([sys.executable, "-c", "import time; time.sleep(30)"], "", 1, self.dir)
        self.assertLess(time.monotonic() - started, 15)


class McpFixesTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.out = str(pathlib.Path(self.tmp.name) / "orders.json")

    def tearDown(self):
        self.tmp.cleanup()

    def tools(self, state=None):
        return mcp_server.GameTools(state or ops_state(), self.out, {})

    def call(self, t, name, args):
        out = io.StringIO()
        mcp_server.serve(t, io.StringIO(json.dumps({"jsonrpc": "2.0", "id": 1, "method": "tools/call",
                                                    "params": {"name": name, "arguments": args}}) + "\n"), out)
        return json.loads(out.getvalue())["result"]

    def test_server_survives_unexpected_errors_and_bad_numbers(self):
        t = self.tools()
        r = self.call(t, "set_standing_orders", {"rules": ["not a rule"]})
        self.assertTrue(r["isError"])
        r = self.call(t, "heli_raid", {"origin": "Red Base", "target_zone": "Blue Front", "delay_min": "soon"})
        self.assertIn("delay_min must be a number", r["content"][0]["text"])
        self.assertEqual(t.spent, 0)

    def test_purchase_cooldowns_and_one_per_cycle(self):
        st = sample_state()
        st["payload"]["purchases"]["purchaseCooldownSec"] = 600
        with self.assertRaisesRegex(ValueError, "on cooldown"):
            self.tools(st).purchase("upgrade", zone="Red Front")
        st["payload"]["purchases"]["purchaseCooldownSec"] = 0
        st["payload"]["economy"]["credits"] = 9000
        t = self.tools(st)
        t.purchase("upgrade", zone="Red Front")
        with self.assertRaisesRegex(ValueError, "one purchase per cycle"):
            t.purchase("upgrade", zone="Red Front")

    def test_freeform_capability_relaunch_costs_its_price(self):
        st = ops_state()
        st["payload"]["capabilities"].append({"id": "FAI-red-Red_Base-Blue_Front-CAS", "origin": "Red Base",
                                              "target": "Blue Front", "role": "CAS", "mission": "attack",
                                              "domain": "air", "available": True, "freeform": True, "price": 1000})
        t = self.tools(st)
        t.launch_capability("FAI-red-Red_Base-Blue_Front-CAS")
        self.assertEqual(t.spent, 1000)

    def test_operation_limits_and_awacs_cooldown(self):
        st = ops_state()
        st["payload"]["economy"]["credits"] = 99999
        st["payload"]["operations"]["limits"] = {"activeFlights": 2, "ambushTeams": 1}
        st["payload"]["operations"]["awacsReadyInMin"] = 7
        t = self.tools(st)
        t.ambush("Red Base", "Red Front", "Blue Front")
        with self.assertRaisesRegex(ValueError, "ambush teams"):
            t.ambush("Red Base", "Red Front", "Blue Front")
        t.heli_raid("Red Base", "Blue Front")
        with self.assertRaisesRegex(ValueError, "limit 2"):
            t.air_assault("Red Base", "Neutral Hill")
        with self.assertRaisesRegex(ValueError, "in 7 min"):
            t.move_awacs("Red Front")

    def test_cancel_orders_and_event_price(self):
        st = sample_state()
        st["payload"]["scheduledOrders"] = [{"order": "r3-c2", "type": "launch_mission", "inMin": 12}]
        st["payload"]["scriptedEvents"] = [{"event": "scuds", "available": True, "price": 1000}]
        t = self.tools(st)
        with self.assertRaisesRegex(ValueError, "not pending"):
            t.cancel_orders(["r9-c9"])
        t.cancel_orders(["r3-c2"])
        self.assertEqual(t.orders[-1], {"type": "cancel_orders", "ids": ["r3-c2"], "id": "c1"})
        t.trigger_event("scuds")
        self.assertEqual(t.spent, 1000)
        self.assertEqual(t.get_overview()["delayedOrdersPending"][0]["order"], "r3-c2")

    def test_standing_orders_limit(self):
        st = sample_state()
        st["payload"]["standingOrdersMax"] = 1
        rule = {"id": "a", "trigger": "zone_lost", "zone": "*",
                "action": {"type": "launch_capability", "capability": "cas1"}}
        with self.assertRaisesRegex(ValueError, "at most 1"):
            self.tools(st).set_standing_orders([rule, dict(rule, id="b")])

    def test_upgrade_price_comes_from_the_mission(self):
        st = ops_state()
        st["payload"]["operations"]["upgradeSlots"][0]["prices"] = {"Red SAM SA-11": 1234}
        t = self.tools(st)
        self.assertIn("cost about 1234", t.upgrade_zone("Red Front", "Red SAM SA-11"))


if __name__ == "__main__":
    unittest.main()
