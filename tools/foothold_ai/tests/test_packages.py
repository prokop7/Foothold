"""Phase 4: packages hold at an IP and push together (Foothold_AI_Packages.lua),
and the matching game tools."""

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

NM = 1852


@unittest.skipIf(lua51 is None, "lupa not installed")
class PackagesLuaTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.saved = pathlib.Path(self.tmp.name)
        self.h = LuaHarness(self.saved)
        self.h.lua.execute((HERE / "command_stub.lua").read_text(encoding="utf-8"))
        # The test map is small (Red Base x=0, Blue Front x=40 km), so short distances.
        self.h.lua.execute("FootholdAIConfig = { wingman = { enabled = false }, "
                           "command = { packages = { holdStartNm = 5 } } }")
        for name in ("Foothold_AI_Core.lua", "Foothold_AI_Command.lua", "Foothold_AI_Ops.lua",
                     "Foothold_AI_Packages.lua"):
            self.h.load_script(name)
        self.g = self.h.g
        self.fs = self.g.FS
        self.x = self.g.FootholdAI.command
        self.lua = self.h.lua

    def tearDown(self):
        self.tmp.cleanup()

    def order(self, **fields):
        return self.x.execute(1, self.lua.table_from(fields))

    def package(self, **extra):
        fields = dict(type="create_package", package="strike1", targetZone="Blue Front", pushInMin=15, ipNm=10)
        fields.update(extra)
        ok, detail = self.order(**fields)
        self.assertTrue(ok, detail)
        return self.x.packages.bySide.red.strike1

    def launch(self, oid, role="CAS", offset=0, origin="Red Base"):
        ok, detail = self.order(id=oid, type="launch_mission", origin=origin, role=role, targetZone="Blue Front",
                                package="strike1", pushOffsetMin=offset)
        self.assertTrue(ok, detail)
        return self.x.missions["red/" + oid].gc, detail

    def fly(self, gc, x, air=True):
        """Puts the flight's live group at x (metres east of Red Base), airborne."""
        gc.state = "inair"
        g = self.g.STUB.groups[gc.name]
        if g is None:
            g = self.g.STUB.makeGroup(gc.name, 0, 1, self.lua.table_from([self.lua.table_from({
                "name": gc.name + "-1", "type": "Su-25T", "air": air,
                "p": self.lua.table_from({"x": x, "y": 3000, "z": 0})})]))
        u = g.units[1]
        u.p.x, u.air = x, air
        return g

    def member(self, pkg, i):
        return pkg.members[i]

    def test_flight_holds_at_ip_then_is_released_at_push(self):
        pkg = self.package(pushWhenReady=False)
        gc, detail = self.launch("o1")
        self.assertIn("package strike1", detail)
        m = self.member(pkg, 1)
        g = self.fly(gc, 3000)           # just took off: too close to its base
        self.h.advance(5)
        self.assertEqual(m.state, "waiting")
        self.fly(gc, 12000)              # on its way
        self.h.advance(5)
        self.assertEqual(m.state, "holding")
        hold = g.controller.pushed[1]
        self.assertEqual(hold.id, "ControlledTask")
        self.assertEqual(hold.params.task.id, "Orbit")
        self.assertAlmostEqual(hold.params.task.params.point.x, 40000 - 10 * NM, delta=1)
        self.assertEqual(hold.params.stopCondition.userFlag, str(m.flag))
        # the orbit ends by itself at the push time (model time) ...
        self.assertAlmostEqual(hold.params.stopCondition.time, self.g.timer.getTime() + (pkg.pushAt - self.g.timer.getAbsTime()),
                               delta=1)
        # ... and the mission sets the flag then too
        self.assertFalse(self.g.STUB.flags[m.flag])
        self.h.advance(15 * 60)
        self.assertTrue(self.g.STUB.flags[m.flag])
        self.assertEqual(m.state, "released")
        self.assertTrue(pkg.pushed)
        pushed = [e for e in self.x.events.red.values() if e.kind == "package_pushed"]
        self.assertEqual(pushed[0].package, "strike1")

    def test_early_push_when_every_flight_holds_and_offsets(self):
        pkg = self.package()
        cas, _ = self.launch("o1", offset=2)
        sead, _ = self.launch("o2", role="SEAD")
        self.fly(cas, 12000)
        self.h.advance(5)
        self.assertFalse(pkg.pushedEarly)        # SEAD still on the ground: no early push
        self.fly(sead, 12000)
        self.h.advance(5)
        self.h.advance(65)
        self.assertTrue(pkg.pushed)
        self.assertTrue(pkg.pushedEarly)
        m_cas, m_sead = self.member(pkg, 1), self.member(pkg, 2)
        self.assertEqual(m_sead.state, "released")
        self.assertEqual(m_cas.state, "holding")   # leaves the IP 2 min after the SEAD
        self.h.advance(120)
        self.assertEqual(m_cas.state, "released")
        self.assertTrue(self.g.STUB.flags[m_cas.flag])

    def test_late_flight_goes_direct(self):
        pkg = self.package(pushWhenReady=False)
        gc, _ = self.launch("o1")
        self.h.advance(16 * 60)
        self.assertTrue(pkg.pushed)
        self.fly(gc, 12000)
        self.h.advance(5)
        self.assertEqual(self.member(pkg, 1).state, "direct")

    def test_flight_already_past_the_ip_goes_direct(self):
        pkg = self.package()
        gc, _ = self.launch("o1")
        self.fly(gc, 30000)   # 10 km from the target, IP is 18.5 km out
        self.h.advance(5)
        self.assertEqual(self.member(pkg, 1).state, "direct")

    def test_retask_restores_hold_and_rtb_aborts(self):
        pkg = self.package()
        gc, _ = self.launch("o1", role="SEAD")
        g = self.fly(gc, 12000)
        self.h.advance(5)
        self.fs.bc.EngageSeadMission(self.fs.bc, "Blue Front", gc.name)
        self.assertEqual(len(g.controller.pushed), 2)   # the hold is pushed again after Foothold re-tasks
        cap = self.lua.eval("setmetatable({ name = '%s' }, GroupCommander)" % gc.name)
        cap._startCapReturnHome(cap, "winchester")
        self.assertEqual(self.member(pkg, 1).state, "aborted")
        self.assertTrue(self.g.STUB.flags[self.member(pkg, 1).flag])

    def test_lost_and_denied_flights(self):
        pkg = self.package()
        gc, _ = self.launch("o1")
        g = self.fly(gc, 12000)
        self.h.advance(5)
        g.destroy(g)
        self.h.advance(5)
        self.assertEqual(self.member(pkg, 1).state, "lost")
        gc2, _ = self.launch("o2", role="SEAD")
        self.fs.red.onManagedSpawnDenied(self.fs.red, gc2, "runway-blocked")
        self.h.advance(5)
        self.assertEqual(self.member(pkg, 2).state, "aborted")

    def test_rejections(self):
        ok, detail = self.order(id="x1", type="launch_mission", origin="Red Base", role="CAS",
                                targetZone="Blue Front", package="nope")
        self.assertFalse(ok)
        self.assertIn("unknown package", detail)
        self.package()
        ok, detail = self.order(type="create_package", package="strike1", targetZone="Blue Front")
        self.assertFalse(ok)
        ok, detail = self.order(id="a1", type="launch_capability", capability="red-arty-bluefront",
                                package="strike1")
        self.assertTrue(ok, detail)
        self.assertIn("ground units do not hold", detail)
        self.assertEqual(len(self.x.packages.bySide.red.strike1.members), 0)

    def test_push_time_is_clamped_and_snapshot(self):
        pkg = self.package(pushInMin=2)
        self.assertAlmostEqual(pkg.pushAt - self.g.timer.getAbsTime(), 10 * 60, delta=1)
        self.launch("o1")
        self.x.request("red", "cycle")
        self.h.advance(2)
        st = json.loads((self.saved / "Missions" / "Saves" / "FootholdAI" / "state_red_command.json")
                        .read_text(encoding="utf-8"))["payload"]
        row = st["packages"][0]
        self.assertEqual(row["package"], "strike1")
        self.assertEqual(row["members"][0]["state"], "waiting")
        self.assertEqual(row["pushInMin"], 10)


class PackagesToolsTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.out = str(pathlib.Path(self.tmp.name) / "orders.json")
        st = sample_state()
        st["payload"]["economy"]["credits"] = 5000
        self.t = mcp_server.GameTools(st, self.out, {})

    def tearDown(self):
        self.tmp.cleanup()

    def test_package_flow(self):
        with self.assertRaisesRegex(ValueError, "unknown package"):
            self.t.launch_mission("Red Base", "CAS", "Blue Front", package="p1")
        msg = self.t.create_package("p1", "Blue Front", push_in_min=5)
        self.assertIn("10-45 min", msg)
        self.t.launch_mission("Red Base", "SEAD", "Blue Front", package="p1")
        msg = self.t.launch_capability("cas1", package="p1", push_offset_min=2)
        self.assertIn("pushes +2 min", msg)
        with self.assertRaisesRegex(ValueError, "ground units"):
            self.t.launch_capability("arty1", package="p1")
        with self.assertRaisesRegex(ValueError, "delay_min"):
            self.t.launch_mission("Red Base", "CAS", "Blue Front", package="p1", delay_min=3)
        with self.assertRaisesRegex(ValueError, "already exists"):
            self.t.create_package("p1", "Blue Front")
        types = [o["type"] for o in self.t.orders]
        self.assertEqual(types, ["create_package", "launch_mission", "launch_capability"])
        self.assertEqual(self.t.orders[0]["pushInMin"], 10.0)
        self.assertEqual(self.t.orders[2]["pushOffsetMin"], 2.0)

    def test_existing_package_from_snapshot(self):
        st = sample_state()
        st["payload"]["packages"] = [{"package": "old", "target": "Blue Front", "pushedMinAgo": 3, "members": []},
                                     {"package": "open", "target": "Blue Front", "pushInMin": 8, "members": []}]
        t = mcp_server.GameTools(st, self.out, {})
        with self.assertRaisesRegex(ValueError, "already pushed"):
            t.launch_capability("cas1", package="old")
        t.launch_capability("cas1", package="open")
        self.assertEqual(t.get_overview()["packages"][1]["package"], "open")


if __name__ == "__main__":
    unittest.main()
