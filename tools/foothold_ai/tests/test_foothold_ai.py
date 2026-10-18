"""Offline tests for the Foothold AI scripts, sidecar and .miz patcher.

Runs the real Lua files in Lua 5.1 (via the `lupa` package) against the stubs in
dcs_stub.lua, and the real sidecar Bridge against the files the Lua side writes.
Dev-only dependency: pip install lupa

    python -m unittest discover -s tools/foothold_ai/tests -v
"""

from __future__ import annotations

import json
import math
import os
import pathlib
import sys
import tempfile
import unittest
import zipfile

HERE = pathlib.Path(__file__).resolve().parent
TOOLS = HERE.parent
REPO = TOOLS.parents[1]
SCRIPTS = REPO / "Common Scripts"
PG_MIZ = REPO / "Missions" / "Foothold_PG_5.3.5_multi_Language_Coldwar-Modern_Vietnam.miz"
sys.path.insert(0, str(TOOLS))

import miz_lua  # noqa: E402
import sidecar  # noqa: E402

try:
    from lupa import lua51
except ImportError:  # pragma: no cover
    lua51 = None

_PG_MISSION = None


def pg_mission() -> dict:
    global _PG_MISSION
    if _PG_MISSION is None:
        with zipfile.ZipFile(PG_MIZ) as zf:
            _, _PG_MISSION = miz_lua.loads(zf.read("mission").decode("utf-8", "surrogateescape"))
    return _PG_MISSION


def to_lua_table(lua, value):
    if isinstance(value, dict):
        t = lua.table()
        for k, v in value.items():
            t[k] = to_lua_table(lua, v)
        return t
    if isinstance(value, miz_lua.LuaNumber):
        f = float(str(value))
        return int(f) if f.is_integer() else f
    return value


class LuaHarness:
    def __init__(self, saved_games: pathlib.Path | None = None):
        self.lua = lua51.LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute((HERE / "dcs_stub.lua").read_text(encoding="utf-8"))
        g = self.lua.globals()
        if saved_games:
            root = str(saved_games).replace("\\", "/") + "/"

            def fix(path):
                return path.replace("\\", "/")

            def attributes(path, attr=None):
                p = fix(path)
                if not os.path.exists(p):
                    return None
                st = os.stat(p)
                info = self.lua.table(modification=int(st.st_mtime_ns // 1_000_000), size=st.st_size)
                return info[attr] if attr else info

            def mkdir(path):
                os.makedirs(fix(path), exist_ok=True)
                return True

            g.lfs = self.lua.table(writedir=lambda: root, mkdir=mkdir, attributes=attributes)
            g._fixpath = fix
            self.lua.execute("""
                local realOpen, realLoadfile = io.open, loadfile
                io.open = function(p, m) return realOpen(_fixpath(p), m) end
                loadfile = function(p) return realLoadfile(_fixpath(p)) end
            """)
        else:
            g.lfs = None

    @property
    def g(self):
        return self.lua.globals()

    def load_script(self, name: str):
        code = (SCRIPTS / name).read_text(encoding="utf-8")
        self.lua.execute(code)

    def logs(self) -> list[str]:
        return list(self.g.STUB.logs.values())

    def texts(self) -> list[str]:
        return [t.text for t in self.g.STUB.texts.values()]

    def advance(self, seconds: float):
        self.g.STUB.advance(seconds)


class FakeClaude:
    def __init__(self):
        self.calls = 0

    def call(self, prompt, schema, system_prompt_file=None):
        self.calls += 1
        return {"output": {"ack": "link ok"}, "latency_ms": 1234, "models": ["claude-opus-5-5"]}


@unittest.skipIf(lua51 is None, "lupa not installed")
class SyntaxTest(unittest.TestCase):
    def test_scripts_compile_as_lua51(self):
        lua = lua51.LuaRuntime(unpack_returned_tuples=True)
        for name in ("Foothold_AI_Core.lua", "Foothold_AI_Wingman.lua", "Foothold_AI_Commander.lua"):
            code = (SCRIPTS / name).read_text(encoding="utf-8")
            ok, err = lua.eval("function(src, name) local f, e = loadstring(src, name) return f ~= nil, e end")(code, name)
            self.assertTrue(ok, f"{name}: {err}")


@unittest.skipIf(lua51 is None, "lupa not installed")
class BridgeTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.saved = pathlib.Path(self.tmp.name)
        self.h = LuaHarness(self.saved)
        self.h.lua.execute("FootholdAIConfig = { wingman = { enabled = false } }")
        self.h.load_script("Foothold_AI_Core.lua")
        self.exchange = self.saved / "Missions" / "Saves" / "FootholdAI"

    def tearDown(self):
        self.tmp.cleanup()

    def test_ping_pong_roundtrip_with_sidecar(self):
        self.h.advance(10)  # first ping
        state = json.loads((self.exchange / "state_red_ping.json").read_text(encoding="utf-8"))
        self.assertEqual(state["schema"], sidecar.STATE_SCHEMA)
        self.assertEqual(state["kind"], "ping")
        self.assertTrue(state["payload"]["wantsClaude"])
        self.assertTrue(state["session"])

        claude = FakeClaude()
        bridge = sidecar.Bridge(self.exchange, claude)
        for side in sidecar.SIDES:
            st = bridge.read_state(side)
            self.assertIsNotNone(st)
            bridge.handle(side, st)
        self.assertEqual(claude.calls, 2)
        self.assertTrue((self.exchange / "orders_red_pong.lua").read_text(encoding="utf-8").startswith("return {"))

        self.h.advance(5)  # poll
        logs = "\n".join(self.h.logs())
        self.assertIn("link ok side=red", logs)
        self.assertIn("link ok side=blue", logs)
        self.assertIn("claudeLatencyMs=1234", logs)

        # The next ping no longer asks for Claude, and the same state is not handled twice.
        self.assertIsNone(bridge.read_state("red"))
        self.h.advance(60)
        st = bridge.read_state("red")
        self.assertFalse(st["payload"]["wantsClaude"])

    def test_orders_from_another_session_are_ignored(self):
        self.h.advance(10)
        sidecar.write_orders(self.exchange, "red", {
            "schema": sidecar.ORDERS_SCHEMA, "side": "red", "seq": 5, "session": "old-session",
            "ackSeq": 1, "kind": "pong", "claude": {"called": True, "ok": True}})
        self.h.advance(5)
        self.assertNotIn("link ok side=red", "\n".join(self.h.logs()))

    def test_malicious_orders_cannot_call_functions(self):
        self.h.advance(10)
        (self.exchange / "orders_red_pong.lua").write_text('return { x = os.exit() }', encoding="utf-8")
        self.h.advance(5)
        self.assertTrue(any("rejected" in line for line in self.h.logs()))

    def test_json_encoder(self):
        encode = self.h.lua.eval("FootholdAI.json.encode")
        t = self.h.lua.eval("{ a = 1, b = 'x\"y\\n', c = { 1, 2, 3 }, d = true, e = 1.5, f = FootholdAI.json.array({}) }")
        self.assertEqual(json.loads(encode(t)),
                         {"a": 1, "b": 'x"y\n', "c": [1, 2, 3], "d": True, "e": 1.5, "f": []})


@unittest.skipIf(lua51 is None, "lupa not installed")
class WingmanTest(unittest.TestCase):
    PLAYER_TYPE = "F-16C_50"

    def setUp(self):
        self.h = LuaHarness(None)
        mission = pg_mission()
        group, unit, country_id = self._client_slot(mission, self.PLAYER_TYPE)
        self.slot_unit = unit
        lua = self.h.lua
        tpl_group = to_lua_table(lua, group)
        tpl_unit = tpl_group["units"][1]
        units = self.h.g._DATABASE.Templates.Units
        units[unit["name"]] = lua.table(Template=tpl_unit, GroupTemplate=tpl_group,
                                        CountryID=country_id, CategoryID=0)
        self.group_name = group["name"]
        self.player = self.h.g.STUB.makeGroup(self.group_name, 0, 2, lua.table_from([lua.table(
            name=unit["name"], type=self.PLAYER_TYPE, player="Tester",
            p=lua.table(x=1000, y=3000, z=2000), hdg=math.pi / 2, spd=200)]))
        self.h.g.STUB.addAirbase("Al Dhafra AFB", 2, 0, lua.table(x=0, y=0, z=0))
        self.h.g.STUB.addAirbase("Far Base", 2, 0, lua.table(x=500000, y=0, z=0))
        self.h.load_script("Foothold_AI_Core.lua")
        self.h.load_script("Foothold_AI_Wingman.lua")
        self.h.advance(3)  # menu setup for players already in a slot

    @staticmethod
    def _client_slot(mission, unit_type):
        for country in mission["coalition"]["blue"]["country"].values():
            for g in (country.get("plane") or {}).get("group", {}).values():
                u = g["units"][1]
                if u["type"] == unit_type and u["skill"] in ("Client", "Player"):
                    return g, u, int(float(str(country["id"])))
        raise AssertionError(f"no client slot for {unit_type}")

    def menu(self, path):
        return self.h.g.STUB.menu(self.group_name, path)

    def wingman(self):
        calls = self.h.g.STUB.addGroupCalls
        return self.h.g.STUB.groups[calls[len(calls)].data.name]

    def test_request_builds_copy_of_player_slot(self):
        self.menu("AI Wingman/Request/One wingman")
        calls = self.h.g.STUB.addGroupCalls
        self.assertEqual(len(calls), 1)
        data = calls[1].data
        u = data.units[1]
        self.assertEqual(u.type, self.PLAYER_TYPE)
        self.assertEqual(u.skill, "Excellent")
        self.assertIsNone(u.parking)
        self.assertIsNone(u.unitId)
        self.assertEqual(u.payload.pylons is not None, self.slot_unit["payload"].get("pylons") is not None)
        self.assertEqual(data.route.points[1].type, "Turning Point")
        self.assertEqual(data.route.points[1].action, "Turning Point")
        # DCS x is north, z (template y) is east. Heading east: behind is -z, right wing is south (-x).
        self.assertAlmostEqual(u.y, 2000 - 600, delta=1)
        self.assertAlmostEqual(u.x, 1000 - 150, delta=1)
        self.assertEqual(u.alt, 3000)
        if isinstance(self.slot_unit.get("callsign"), dict):
            self.assertEqual(int(u.callsign[3]), int(float(str(self.slot_unit["callsign"][3]))) + 1)
        self.assertNotEqual(data.task, "Nothing")

        self.h.advance(1)
        ctrl = self.wingman().controller
        self.assertEqual(ctrl.task.id, "Follow")
        self.assertEqual(ctrl.task.params.groupId, self.player.id)
        self.assertEqual(ctrl.options[0], 2)  # OPEN_FIRE while following
        self.assertIn("Two, joining on your wing.", self.h.texts())

    def test_second_request_is_refused(self):
        self.menu("AI Wingman/Request/One wingman")
        self.h.advance(1)
        self.menu("AI Wingman/Request/Three wingmen (4-ship)")
        self.assertEqual(len(self.h.g.STUB.addGroupCalls), 1)
        self.assertTrue(any("already have" in t for t in self.h.texts()))

    def test_three_wingmen(self):
        self.menu("AI Wingman/Request/Three wingmen (4-ship)")
        data = self.h.g.STUB.addGroupCalls[1].data
        self.assertEqual(len(data.units), 3)
        names = {data.units[i].name for i in (1, 2, 3)}
        self.assertEqual(len(names), 3)

    def test_attack_ground_then_auto_rejoin(self):
        self.menu("AI Wingman/Request/One wingman")
        self.h.advance(1)
        self.menu("AI Wingman/Attack/Ground targets near me")
        ctrl = self.wingman().controller
        tasks = ctrl.task.params.tasks
        self.assertEqual(tasks[1].id, "EngageTargetsInZone")
        self.assertEqual(tasks[1].params.zoneRadius, 5 * 1852)
        self.assertEqual(tasks[1].params.targetTypes[1], "Ground Units")
        self.assertEqual(tasks[1].params.point.x, 1000)
        self.assertEqual(tasks[1].params.point.y, 2000)
        self.assertEqual(tasks[2].id, "Orbit")
        self.assertEqual(ctrl.options[0], 0)  # WEAPON_FREE
        self.h.advance(600)
        self.assertEqual(ctrl.task.id, "Follow")

    def test_attack_map_mark(self):
        self.menu("AI Wingman/Request/One wingman")
        self.h.advance(1)
        self.menu('AI Wingman/Attack/My "wm" map mark')
        self.assertTrue(any("No \"wm\" map mark" in t for t in self.h.texts()))
        lua = self.h.lua
        self.h.g.STUB.fire(lua.table(id=25, idx=7, text="WM tanks", coalition=2,
                                     pos=lua.table(x=5000, y=0, z=6000)))
        self.menu('AI Wingman/Attack/My "wm" map mark')
        task = self.wingman().controller.task
        self.assertEqual(task.params.tasks[1].params.point.x, 5000)
        self.assertEqual(task.params.tasks[1].params.point.y, 6000)

    def test_status_and_weapons(self):
        self.menu("AI Wingman/Request/One wingman")
        self.h.advance(1)
        self.menu("AI Wingman/Weapons/Weapons hold")
        self.assertEqual(self.wingman().controller.options[0], 4)
        self.menu("AI Wingman/Status")
        self.assertTrue(any("fuel 80%" in t and "AIM-9M" in t for t in self.h.texts()))

    def test_player_death_sends_wingman_home_and_cleanup_after_landing(self):
        self.menu("AI Wingman/Request/One wingman")
        self.h.advance(1)
        wg = self.wingman()
        player_unit = self.player.units[1]
        self.h.g.STUB.fire(self.h.lua.table(id=8, initiator=player_unit))
        self.assertEqual(wg.route[2].kind, "land")
        self.assertEqual(wg.route[2].airbase, "Al Dhafra AFB")
        self.h.g.STUB.fire(self.h.lua.table(id=4, initiator=wg.units[1]))
        self.h.advance(61)
        self.assertFalse(wg.alive)
        self.menu("AI Wingman/Status")
        self.assertTrue(any("No wingman" in t for t in self.h.texts()))

    def test_requires_airborne(self):
        self.player.units[1].air = False
        self.menu("AI Wingman/Request/One wingman")
        self.assertEqual(len(self.h.g.STUB.addGroupCalls), 0)
        self.assertTrue(any("airborne" in t for t in self.h.texts()))

    def test_type_override_disables(self):
        self.h.g.FootholdAI.config.wingman.typeOverride[self.PLAYER_TYPE] = False
        self.menu("AI Wingman/Request/One wingman")
        self.assertEqual(len(self.h.g.STUB.addGroupCalls), 0)
        self.assertTrue(any("disabled" in t for t in self.h.texts()))

    def test_dismiss(self):
        self.menu("AI Wingman/Request/One wingman")
        self.h.advance(1)
        wg = self.wingman()
        self.menu("AI Wingman/Dismiss")
        self.assertFalse(wg.alive)


class LuaWriterTest(unittest.TestCase):
    def test_to_lua_roundtrip(self):
        if lua51 is None:
            self.skipTest("lupa not installed")
        value = {"kind": "x", "n": 3, "f": 0.25, "list": [1, "a\"b\n"], "nested": {"ok": True}}
        lua = lua51.LuaRuntime()
        t = lua.execute(sidecar.to_lua(value).join(["return ", ""]))
        self.assertEqual(t["kind"], "x")
        self.assertEqual(t["list"][2], "a\"b\n")
        self.assertTrue(t["nested"]["ok"])


class PatchMizTest(unittest.TestCase):
    def test_patch_and_repatch(self):
        import patch_miz
        with tempfile.TemporaryDirectory() as tmp:
            out1 = pathlib.Path(tmp) / "a.miz"
            out2 = pathlib.Path(tmp) / "b.miz"
            patch_miz.main([str(PG_MIZ), "-o", str(out1)])
            patch_miz.main([str(out1), "-o", str(out2)])
            with zipfile.ZipFile(out2) as zf:
                _, mission = miz_lua.loads(zf.read("mission").decode("utf-8", "surrogateescape"))
                names = zf.namelist()
            rules = [r for r in mission["trigrules"].values() if r.get("comment") == "Foothold AI"]
            self.assertEqual(len(rules), 1)
            self.assertIn("l10n/DEFAULT/Foothold_AI_Core.lua", names)
            self.assertIn("l10n/DEFAULT/Foothold_AI_Wingman.lua", names)


if __name__ == "__main__":
    unittest.main()
