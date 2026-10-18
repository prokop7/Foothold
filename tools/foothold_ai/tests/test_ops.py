"""Offline tests for the economy, the RED operations (Foothold_AI_Ops.lua),
fair jamming, and the matching MCP game tools."""

from __future__ import annotations

import json
import pathlib
import sys
import tempfile
import unittest

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent))

import mcp_server  # noqa: E402
from test_command import sample_state  # noqa: E402
from test_foothold_ai import LuaHarness, lua51  # noqa: E402


class OpsHarness:
    """Loads Core, Command and Ops against the stubs; mixed into test cases."""
    config = "FootholdAIConfig = { wingman = { enabled = false } }"

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.saved = pathlib.Path(self.tmp.name)
        self.h = LuaHarness(self.saved)
        self.h.lua.execute((HERE / "command_stub.lua").read_text(encoding="utf-8"))
        self.h.lua.execute(self.config)
        for name in ("Foothold_AI_Core.lua", "Foothold_AI_Command.lua", "Foothold_AI_Ops.lua"):
            self.h.load_script(name)
        self.g = self.h.g
        self.fs = self.g.FS
        self.x = self.g.FootholdAI.command
        self.lua = self.h.lua

    def tearDown(self):
        self.tmp.cleanup()

    def order(self, side, **fields):
        ok, detail = self.x.execute(side, self.lua.table_from(fields))
        return ok, detail

    def calls(self, name):
        return [c for c in self.fs.calls.values() if c.name == name]

    def credits(self, side=1):
        return self.fs.bc.accounts[side]

    def ledger(self, side="red"):
        return [(e.amount, e.what) for e in self.x.ledger[side].values()]

    def unit(self, group, side, category, x, air=True, attrs=None, player=None):
        """Creates a one-unit group and returns the unit."""
        self.g.STUB.makeGroup(group, category, side, self.lua.table_from([self.lua.table_from({
            "name": group + "-1", "type": "T", "player": player, "air": air,
            "p": self.lua.table_from({"x": x, "y": 0, "z": 0}),
            "attrs": self.lua.table_from(attrs or {})})]))
        return self.g.STUB.units[group + "-1"]

    def fire(self, event_id, initiator, target=None):
        self.g.STUB.fire(self.lua.table_from({"id": event_id, "initiator": initiator, "target": target}))



@unittest.skipIf(lua51 is None, "lupa not installed")
class OpsLuaTest(OpsHarness, unittest.TestCase):
    # -- economy ------------------------------------------------------------
    def test_ground_kill_paid_at_once_air_kill_on_landing(self):
        start = self.credits()
        tank = self.unit("red tank", 1, 2, 0, air=False)
        victim = self.unit("blue apc", 2, 2, 100, air=False)
        self.fire(28, tank, victim)
        self.assertEqual(self.credits(), start + 10)
        jet = self.unit("red jet", 1, 0, 0)
        hornet = self.unit("blue jet", 2, 0, 100)
        self.fire(28, jet, hornet)
        self.assertEqual(self.credits(), start + 10)
        self.assertEqual(self.x.unpaidKills["red jet-1"].amount, 50)
        self.fire(4, jet)   # landed
        self.assertEqual(self.credits(), start + 60)
        self.assertIn((50, "1 kills paid on landing (red jet-1)"), self.ledger())

    def test_lost_aircraft_keeps_a_quarter(self):
        start = self.credits()
        jet = self.unit("red jet", 1, 0, 0)
        for i in range(2):
            self.fire(28, jet, self.unit(f"blue jet {i}", 2, 0, 100))
        self.fire(8, jet)   # dead
        self.assertEqual(self.credits(), start + 25)
        self.assertIsNone(self.x.unpaidKills["red jet-1"])

    def test_no_reward_for_players_blue_or_friendly_kills(self):
        start_red, start_blue = self.credits(1), self.credits(2)
        player = self.unit("red player", 1, 2, 0, air=False, player="Ivan")
        self.fire(28, player, self.unit("blue apc", 2, 2, 100, air=False))
        blue = self.unit("blue tank", 2, 2, 0, air=False)
        self.fire(28, blue, self.unit("red apc", 1, 2, 100, air=False))
        tank = self.unit("red tank", 1, 2, 0, air=False)
        self.fire(28, tank, self.unit("red apc 2", 1, 2, 100, air=False))
        self.assertEqual((self.credits(1), self.credits(2)), (start_red, start_blue))

    def test_sam_kill_and_capture_reward(self):
        start = self.credits()
        tank = self.unit("red tank", 1, 2, 0, air=False)
        self.fire(28, tank, self.unit("blue hawk", 2, 2, 100, air=False, attrs={"SAM SR": True}))
        self.assertEqual(self.credits(), start + 30)
        self.fs.red.recordZoneOwnershipChange(self.fs.red, "Neutral Hill", 0, 1)
        self.assertEqual(self.credits(), start + 230)
        self.assertEqual(self.ledger()[0], (200, "captured Neutral Hill"))

    def test_snapshot_economy_and_operations(self):
        self.order(1, type="supply_airlift", zone="Red Front")
        self.x.request("red", "cycle")
        self.h.advance(2)
        st = json.loads((self.saved / "Missions" / "Saves" / "FootholdAI" / "state_red_command.json")
                        .read_text(encoding="utf-8"))["payload"]
        econ = st["economy"]
        self.assertEqual(econ["credits"], 5000 - 750)
        self.assertEqual(econ["incomePerMinute"], (2 + 1 + 1) * 6)
        self.assertEqual(econ["sinceLastSnapshot"]["spentOnOrders"], 750)
        self.assertEqual(econ["ledger"][0]["what"], "supply airlift to Red Front")
        self.assertTrue(econ["killRewards"])
        ops = st["operations"]
        self.assertEqual({e["template"]: e["category"] for e in ops["deployCatalog"]},
                         {"Red Armour Group": "armor", "Red SAM SA-11": "sam", "Red SAM SHORAD SA-8": "shorad"})
        self.assertEqual(ops["prices"]["deploy"]["sam_long"], 5000)
        self.assertEqual([s["system"] for s in ops["fireSystems"]], ["scud", "smerch"])
        self.assertEqual(ops["heloOrigins"], ["Red Base"])
        self.assertIn("unavailable", ops["jammer"])
        self.assertEqual(ops["upgradeSlots"][0]["templates"]["sam"], ["Red SAM SA-11"])
        roles = {r["role"]: r for r in st["freeform"]["roles"]}
        self.assertEqual(roles["CAS"]["templates"], ["RED_SU25T_CAS", "RED_L39_CAS"])
        # BLUE gets no RED operations
        self.x.request("blue", "cycle")
        self.h.advance(2)
        blue = json.loads((self.saved / "Missions" / "Saves" / "FootholdAI" / "state_blue_command.json")
                          .read_text(encoding="utf-8"))["payload"]
        self.assertNotIn("operations", blue)

    def test_freeform_template_choice(self):
        ok, detail = self.order(1, id="o1", type="launch_mission", origin="Red Base", role="CAS",
                                targetZone="Blue Front", template="BLUE_A10_CAS")
        self.assertFalse(ok)
        self.assertIn("not a CAS template", detail)
        ok, detail = self.order(1, id="o2", type="launch_mission", origin="Red Base", role="CAS",
                                targetZone="Blue Front", template="RED_L39_CAS")
        self.assertTrue(ok, detail)
        cap = self.fs.bc.directorCapabilitiesById["FAI-red-Red_Base-Blue_Front-CAS-RED_L39_CAS"]
        # Foothold resolves the side from a template set, so a single group is published as one
        self.assertEqual(list(self.g[cap.template].values()), ["RED_L39_CAS"])

    # -- wave 1 ---------------------------------------------------------------
    def test_deploy_forces_limits_cost_and_persistence(self):
        start = self.credits()
        ok, detail = self.order(1, type="deploy_forces", zone="Red Front", template="Red Armour Group")
        self.assertTrue(ok, detail)
        self.assertEqual(self.credits(), start - 1000)
        self.order(1, type="deploy_forces", zone="Red Front", template="Red SAM SHORAD SA-8")
        ok, detail = self.order(1, type="deploy_forces", zone="Red Front", template="Red Armour Group")
        self.assertFalse(ok)
        self.assertIn("already has 2", detail)
        self.assertFalse(self.order(1, type="deploy_forces", zone="Blue Front", template="Red Armour Group")[0])
        self.assertFalse(self.order(1, type="deploy_forces", zone="Red Base", template="Scuds")[0])
        self.assertFalse(self.order(2, type="deploy_forces", zone="Red Base", template="Red Armour Group")[0])
        files = list((self.saved / "Missions" / "Saves" / "FootholdAI").glob("ops_*.lua"))
        self.assertEqual(len(files), 1)
        # restart: the groups come back
        h2 = LuaHarness(self.saved)
        h2.lua.execute((HERE / "command_stub.lua").read_text(encoding="utf-8"))
        h2.lua.execute(self.config)
        for name in ("Foothold_AI_Core.lua", "Foothold_AI_Command.lua", "Foothold_AI_Ops.lua"):
            h2.load_script(name)
        deployed = h2.g.FootholdAI.command.ops.deployed
        self.assertEqual(sorted(d.template for d in deployed.values()), ["Red Armour Group", "Red SAM SHORAD SA-8"])

    def test_upgrade_zone_exact_template(self):
        ok, detail = self.order(1, type="upgrade_zone", zone="Red Front", template="Red Armour Group")
        self.assertFalse(ok)
        self.assertIn("does not take", detail)
        start = self.credits()
        ok, detail = self.order(1, type="upgrade_zone", zone="Red Front", template="Red SAM SA-11")
        self.assertTrue(ok, detail)
        self.assertEqual(self.fs.bc.byName["Red Front"].extraUsed, "Red SAM SA-11")
        self.assertEqual(len(self.calls("upgrade")), 1)
        self.assertEqual(self.credits(), start - 2000)
        self.assertIn("no free upgrade slot",
                      self.order(1, type="upgrade_zone", zone="Red Front", template="Red SAM SA-11")[1])

    def test_fire_mission_range_cooldown_and_firing(self):
        self.g.FootholdAI.config.command.ops.fireSystems.smerch.rangeKm = 50
        ok, detail = self.order(1, type="fire_mission", system="smerch", origin="Red Base", targetZone="Blue Base")
        self.assertFalse(ok)
        self.assertIn("60 km away, smerch reaches 50 km", detail)
        self.assertFalse(self.order(1, type="fire_mission", system="iskander", origin="Red Base",
                                    targetZone="Blue Base")[0])   # era/template not available
        start = self.credits()
        ok, detail = self.order(1, type="fire_mission", system="scud", origin="Red Base", targetZone="Blue Base")
        self.assertTrue(ok, detail)
        self.assertEqual(self.credits(), start - 800)
        self.assertIn("reloading", self.order(1, type="fire_mission", system="scud", origin="Red Base",
                                              targetZone="Blue Base")[1])
        self.assertEqual(len(self.calls("fireAtZone")), 0)
        self.h.advance(61)
        fired = self.calls("fireAtZone")
        self.assertEqual(len(fired), 1)
        self.assertEqual(fired[0].args[1], "Blue Base")
        self.assertEqual(self.x.events.red[1].result, "fired")
        battery = fired[0].args[2]
        self.assertIsNotNone(self.g.STUB.groups[battery])
        self.h.advance(1200)
        self.assertIsNone(self.g.STUB.groups[battery])

    def test_fire_mission_needs_credits(self):
        self.fs.bc.accounts[1] = 100
        ok, detail = self.order(1, type="fire_mission", system="scud", origin="Red Base", targetZone="Blue Base")
        self.assertFalse(ok)
        self.assertIn("not enough credits", detail)

    def test_supply_airlift_and_awacs(self):
        self.assertTrue(self.order(1, type="supply_airlift", zone="Red Front")[0])
        self.assertEqual(self.calls("supplyStock")[0].args[2], 3)
        self.assertIn("no RED AWACS", self.order(1, type="move_awacs", zone="Red Front")[1])
        self.g._awacsFG[1] = self.g.STUB.makeGroup("AWACS_RED", 0, 1, self.lua.table_from([self.lua.table_from({
            "name": "aw-1", "type": "E-3A", "p": self.lua.table_from({"x": 0, "y": 9000, "z": 0})})]))
        ok, detail = self.order(1, type="move_awacs", zone="Red Front", headingDeg=90, legNm=30)
        self.assertTrue(ok, detail)
        # Foothold's own repositioning keeps Claude's station
        self.g.setAwacsRacetrack(1, self.lua.table_from({"x": 1, "z": 1}), 0, 10, "Somewhere")
        calls = self.calls("setAwacsRacetrack")
        self.assertEqual([c.args[2] for c in calls], ["Red Front", "Red Front"])
        self.g.setAwacsRacetrack(2, self.lua.table_from({"x": 1, "z": 1}), 0, 10, "Blue Base")
        self.assertEqual(self.calls("setAwacsRacetrack")[-1].args[2], "Blue Base")

    # -- wave 2 ---------------------------------------------------------------
    def land_flight(self, at=None):
        flights = self.x.ops.flights
        name = next(iter(flights.keys()))
        f = flights[name]
        u = self.g.STUB.groups[name].units[1]
        p = at or (f.lz.x, f.lz.z)
        u.p.x, u.p.z, u.air = p[0], p[1], False
        self.h.advance(5)
        return name, f

    def test_heli_raid_lands_gun_and_fires(self):
        start = self.credits()
        self.assertIn("cannot launch helicopters",
                      self.order(1, type="heli_raid", origin="Red Front", targetZone="Blue Front")[1])
        ok, detail = self.order(1, type="heli_raid", origin="Red Base", targetZone="Blue Front", gun="akatsia")
        self.assertTrue(ok, detail)
        self.assertEqual(self.credits(), start - 1000)
        call = self.g.STUB.addGroupCalls[1]
        self.assertEqual(call.countryId, 81)
        route = call.data.route.points
        self.assertEqual(route[2].task.params.tasks[1].id, "Land")
        # landing site 0.8 x 17 km from Blue Front (x=40 km) toward Red Base (x=0)
        self.assertAlmostEqual(route[2].x, 40000 - 13600, delta=900)
        name, f = self.land_flight()
        self.assertEqual(f.phase, "returning")
        self.assertEqual(f.result, "gun unloaded")
        self.h.advance(31)
        fired = self.calls("fireAtZone")
        self.assertEqual(fired[0].args[1], "Blue Front")
        self.assertTrue(fired[0].args[2].endswith("-GUN#001"))
        self.land_flight(at=(0, 0))
        self.assertIsNone(self.x.ops.flights[name])
        self.assertIsNone(self.g.STUB.groups[name])
        ended = [e for e in self.x.events.red.values() if e.kind == "operation_ended"]
        self.assertIn("returned", ended[0].outcome)

    def test_heli_shot_down_before_landing(self):
        self.order(1, type="heli_raid", origin="Red Base", targetZone="Blue Front")
        name = next(iter(self.x.ops.flights.keys()))
        self.g.STUB.groups[name].destroy(self.g.STUB.groups[name])
        self.h.advance(5)
        ended = [e for e in self.x.events.red.values() if e.kind == "operation_ended"]
        self.assertEqual(ended[0].outcome, "shot down before landing")
        self.assertEqual(len(self.calls("fireAtZone")), 0)

    def test_air_assault_starts_capture(self):
        self.assertIn("neutral", self.order(1, type="air_assault", origin="Red Base", targetZone="Blue Front")[1])
        ok, detail = self.order(1, type="air_assault", origin="Red Base", targetZone="Neutral Hill")
        self.assertTrue(ok, detail)
        name, f = self.land_flight()
        cap = self.calls("startCapture")
        self.assertEqual((cap[0].args[1], cap[0].args[2], cap[0].args[3]), ("Neutral Hill", 1, name))
        self.assertEqual(f.result, "troops capturing Neutral Hill")

    def test_ambush_team(self):
        ok, detail = self.order(1, type="ambush", origin="Red Base", fromZone="Red Front", towardZone="Blue Front",
                                fraction=0.5, team="manpads")
        self.assertTrue(ok, detail)
        self.land_flight()
        spawn = self.g.STUB.spawns[1]
        self.assertEqual(spawn.template, "Igla")
        self.assertAlmostEqual(spawn.x, 30000, delta=1600)

    def test_jam_needs_template(self):
        ok, detail = self.order(1, type="jam", targetZone="Blue Front")
        self.assertFalse(ok)
        self.assertIn("ewAircraftRed", detail)

    def add_jammer_template(self):
        self.lua.execute("""
            _DATABASE.Templates.Groups['ewAircraftRed'] = { CountryID = 81, CategoryID = 0, CoalitionID = 1,
                Template = { name = 'ewAircraftRed', units = { { name = 'ew-1', type = 'Su-24MR' } } } }
            FS.bc.byName['Blue Front'].built = { 'blue sam near', 'blue sam far' }
            STUB.makeGroup('blue sam near', 2, 2, { { name = 'near-sr', type = 'Hawk sr', air = false,
                attrs = { ['SAM SR'] = true }, p = { x = 40000, y = 0, z = 0 } } })
            STUB.makeGroup('blue sam far', 2, 2, { { name = 'far-tr', type = 'Hawk tr', air = false,
                attrs = { ['SAM TR'] = true }, p = { x = 40000, y = 0, z = 90000 } } })
        """)

    def test_red_jammer_jams_only_radars_in_range(self):
        self.add_jammer_template()
        ok, detail = self.order(1, type="jam", targetZone="Blue Front")
        self.assertTrue(ok, detail)
        self.h.advance(1)
        jammer = next(iter(self.x.ops.flights.keys()))
        task = self.g.STUB.groups[jammer].controller.task
        orbit = task.params.route.points[2].task.params.tasks[1]
        self.assertEqual(orbit.id, "Orbit")
        # the jammer is on station 25 nm from Blue Front toward Red Base
        u = self.g.STUB.groups[jammer].units[1]
        u.p.x = orbit.params.point.x
        self.h.advance(10)
        near, far = self.g.STUB.units["near-sr"].controller, self.g.STUB.units["far-tr"].controller
        self.assertEqual((near.options[0], near.options[9]), (4, 1))
        self.assertIsNone(far.options[0])
        self.assertIn("a jammer is already flying", self.order(1, type="jam", targetZone="Blue Front")[1])
        self.g.STUB.groups[jammer].destroy(self.g.STUB.groups[jammer])
        self.h.advance(10)
        self.assertEqual((near.options[0], near.options[9]), (2, 2))

    def test_blue_shop_jammer_obeys_the_same_range(self):
        self.add_jammer_template()
        self.lua.execute("""
            FS.bc.byName['Red Front'].built = { 'red sam' }
            STUB.makeGroup('red sam', 2, 1, { { name = 'red-sr', type = 'SA-11 sr', air = false,
                attrs = { ['SAM SR'] = true }, p = { x = 20000, y = 0, z = 0 } } })
            STUB.makeGroup('ewAircraft', 0, 2, { { name = 'ew-blue', type = 'FA-18C_hornet',
                p = { x = 300000, y = 7000, z = 0 } } })
        """)
        self.assertIsNone(self.fs.bc.jamRadarsAtZone(self.fs.bc, "ewAircraft", "Red Front"))
        self.h.advance(10)
        sr = self.g.STUB.units["red-sr"].controller
        self.assertIsNone(sr.options[0])     # 150 nm away: no jamming
        # BLUE's jammer keeps its Mission Editor route and lifetime
        self.assertIsNone(self.g.STUB.groups["ewAircraft"].controller.task)
        self.g.STUB.units["ew-blue"].p.x = 20000 + 25 * 1852
        self.h.advance(10)
        self.assertEqual(sr.options[0], 4)
        self.assertEqual(self.fs.bc.jamRadarsAtZone(self.fs.bc, "ewAircraft", "Blue Front"), "Can not jam friendly zone")


@unittest.skipIf(lua51 is None, "lupa not installed")
class CapabilityFeeTest(OpsLuaTest):
    config = "FootholdAIConfig = { wingman = { enabled = false }, command = { economy = { capabilityFee = { red = 0.5 } } } }"

    def test_capability_fee_charged(self):
        start = self.credits()
        ok, detail = self.order(1, id="o1", type="launch_capability", capability="red-cap-front")
        self.assertTrue(ok, detail)
        self.assertIn("fee 250", detail)
        self.assertEqual(self.credits(), start - 250)
        self.fs.bc.accounts[1] = 100
        ok, detail = self.order(1, id="o2", type="launch_capability", capability="red-cas-bluefront")
        self.assertFalse(ok)
        self.assertIn("not enough credits", detail)


def ops_state():
    st = sample_state("red")
    p = st["payload"]
    p["economy"] = {"credits": 3000, "capabilityFee": 0.5}
    p["freeform"]["roles"][0]["templates"] = ["RED_SU25T_CAS"]
    p["zones"].append({"name": "Neutral Hill", "side": "neutral", "xKm": 30, "zKm": 20, "neighbors": []})
    p["operations"] = {
        "prices": {"deploy": {"armor": 1000, "sam": 2000, "sam_long": 5000, "other": 1000}, "airlift": 1500,
                   "heli_raid": 1000, "air_assault": 500, "ambush": 500, "jam": 500, "awacs": 0},
        "deployCatalog": [{"template": "Red Armour Group", "category": "armor"}],
        "deployed": [{"zone": "Red Front", "template": "Red Armour Group", "category": "armor"}],
        "deployLimits": {"perZone": 2, "total": 12},
        "upgradeSlots": [{"zone": "Red Front", "templates": {"sam": ["Red SAM SA-11"]}}],
        "fireSystems": [{"system": "scud", "rangeKm": 280, "salvo": 1, "price": 800, "readyInMin": 0},
                        {"system": "smerch", "rangeKm": 30, "salvo": 12, "price": 2500, "readyInMin": 0}],
        "heloOrigins": ["Red Base"], "heloRangeKm": 150,
        "raidGuns": [{"gun": "akatsia", "rangeKm": 17}], "ambushTeams": ["manpads"],
        "flights": [], "groundTeams": [], "batteries": [],
        "jammer": {"unavailable": "no RED jammer aircraft in this mission"},
        "awacs": {"available": True}, "airliftUnits": 3,
    }
    return st


class OpsToolsTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.out = str(pathlib.Path(self.tmp.name) / "orders.json")
        self.t = mcp_server.GameTools(ops_state(), self.out, {})

    def tearDown(self):
        self.tmp.cleanup()

    def test_deploy_and_upgrade(self):
        self.t.deploy_forces("Red Front", "Red Armour Group")
        with self.assertRaisesRegex(ValueError, "already has 2"):
            self.t.deploy_forces("Red Front", "Red Armour Group")
        with self.assertRaisesRegex(ValueError, "not one of your zones"):
            self.t.deploy_forces("Blue Front", "Red Armour Group")
        with self.assertRaisesRegex(ValueError, "does not take"):
            self.t.upgrade_zone("Red Front", "Red Armour Group")
        msg = self.t.upgrade_zone("Red Front", "Red SAM SA-11")
        self.assertIn("cost about 2000", msg)
        self.assertEqual(self.t.spent, 3000)

    def test_fire_mission_and_budget(self):
        with self.assertRaisesRegex(ValueError, "reaches 30 km"):
            self.t.fire_mission("smerch", "Red Base", "Blue Front")
        with self.assertRaisesRegex(ValueError, "enemy zone"):
            self.t.fire_mission("scud", "Red Base", "Red Front")
        self.t.fire_mission("scud", "Red Base", "Blue Front", delay_min=3)
        self.assertEqual(self.t.orders[-1], {"type": "fire_mission", "system": "scud", "origin": "Red Base",
                                             "targetZone": "Blue Front", "delaySec": 180, "id": "c1"})
        with self.assertRaisesRegex(ValueError, "already ordered"):
            self.t.fire_mission("scud", "Red Base", "Blue Front")

    def test_helicopter_operations_and_jammer(self):
        with self.assertRaisesRegex(ValueError, "cannot launch helicopters"):
            self.t.heli_raid("Red Front", "Blue Front")
        self.t.heli_raid("Red Base", "Blue Front")
        with self.assertRaisesRegex(ValueError, "neutral"):
            self.t.air_assault("Red Base", "Blue Front")
        self.t.air_assault("Red Base", "Neutral Hill")
        self.t.ambush("Red Base", "Red Front", "Blue Front", fraction=1.5)
        self.assertEqual(self.t.orders[-1]["fraction"], 0.9)
        with self.assertRaisesRegex(ValueError, "no RED jammer"):
            self.t.jam("Blue Front")
        with self.assertRaisesRegex(ValueError, "not enough credits"):
            self.t.supply_airlift("Red Front")

    def test_capability_fee_and_template(self):
        msg = self.t.launch_capability("cas1")
        self.assertTrue(msg.startswith("queued"))
        self.assertEqual(self.t.spent, 500)
        with self.assertRaisesRegex(ValueError, "not a CAS template"):
            self.t.launch_mission("Red Base", "CAS", "Blue Front", template="BLUE_A10")
        self.t.launch_mission("Red Base", "CAS", "Blue Front", template="RED_SU25T_CAS")
        self.assertEqual(self.t.orders[-1]["template"], "RED_SU25T_CAS")

    def test_blue_has_no_operations(self):
        t = mcp_server.GameTools(sample_state("blue"), self.out, {})
        with self.assertRaisesRegex(ValueError, "RED only"):
            t.deploy_forces("Red Front", "x")
        names = {s["name"] for s in mcp_server.tool_specs("blue")}
        self.assertNotIn("fire_mission", names)
        self.assertIn("jam", {s["name"] for s in mcp_server.tool_specs("red")})


if __name__ == "__main__":
    unittest.main()
