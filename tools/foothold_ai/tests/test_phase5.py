"""Phase 5: players join AI packages, plain-language wingman orders."""

from __future__ import annotations

import json
import pathlib
import sys
import tempfile
import unittest

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent))

import sidecar  # noqa: E402
from test_foothold_ai import LuaHarness, lua51  # noqa: E402

NM = 1852
PLAYER = "Viper 1"


@unittest.skipIf(lua51 is None, "lupa not installed")
class Phase5Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.saved = pathlib.Path(self.tmp.name)
        self.exchange = self.saved / "Missions" / "Saves" / "FootholdAI"
        self.h = LuaHarness(self.saved)
        self.h.lua.execute((HERE / "command_stub.lua").read_text(encoding="utf-8"))
        self.h.lua.execute("FootholdAIConfig = { command = { packages = { holdStartNm = 5 } } }")
        self.g = self.h.g
        self.lua = self.h.lua
        # a BLUE player in an F-16 near Blue Base (x = 60 km)
        self.player = self.g.STUB.makeGroup(PLAYER, 0, 2, self.lua.table_from([self.lua.table_from({
            "name": "viper-1", "type": "F-16C_50", "player": "Ivan",
            "p": self.lua.table_from({"x": 55000, "y": 6000, "z": 0})})]))
        for name in ("Foothold_AI_Core.lua", "Foothold_AI_Wingman.lua", "Foothold_AI_Command.lua",
                     "Foothold_AI_Ops.lua", "Foothold_AI_Packages.lua"):
            self.h.load_script(name)
        self.h.advance(4)   # menus for players already in a slot
        self.x = self.g.FootholdAI.command
        self.fs = self.g.FS

    def tearDown(self):
        self.tmp.cleanup()

    def texts(self):
        return [t.text for t in self.g.STUB.texts.values()]

    def menu(self, path):
        return self.g.STUB.menu(PLAYER, path)

    def move_player(self, x):
        self.player.units[1].p.x = x


class PlayerPackagesTest(Phase5Base):
    def blue_package(self, **extra):
        fields = dict(type="create_package", package="Anvil", targetZone="Red Front", pushInMin=20, ipNm=10)
        fields.update(extra)
        ok, detail = self.x.execute(2, self.lua.table_from(fields))
        self.assertTrue(ok, detail)
        return self.x.packages.bySide.blue.Anvil

    def test_list_and_join(self):
        self.menu("AI Packages/List packages")
        self.assertIn("No AI packages", self.texts()[-1])
        pkg = self.blue_package()
        self.menu("AI Packages/List packages")
        self.assertIn("1. Anvil on Red Front, push in 20 min", self.texts()[-1])
        self.menu("AI Packages/Join/Package 1")
        pl = pkg.players[PLAYER]
        self.assertEqual(pl.state, "joined")
        self.assertIn("Joined Anvil on Red Front", self.texts()[-1])
        marks = [m.text for m in self.g.STUB.marks.values()]
        self.assertTrue(any("Anvil IP" in t for t in marks))
        self.assertTrue(any("Anvil target: Red Front" in t for t in marks))
        joined = [e for e in self.x.events.blue.values() if e.kind == "player_joined_package"]
        self.assertEqual(joined[0].player, "Ivan")

    def test_ai_waits_at_ip_for_the_player_then_push(self):
        pkg = self.blue_package()
        self.menu("AI Packages/Join/Package 1")
        ok, detail = self.x.execute(2, self.lua.table_from(dict(id="b1", type="launch_mission", origin="Blue Base",
                                                                 role="CAS", targetZone="Red Front", package="Anvil")))
        self.assertTrue(ok, detail)
        gc = self.x.missions["blue/b1"].gc
        gc.state = "inair"
        self.g.STUB.makeGroup(gc.name, 0, 2, self.lua.table_from([self.lua.table_from({
            "name": gc.name + "-1", "type": "F-16C_50", "p": self.lua.table_from({"x": 48000, "y": 5000, "z": 0})})]))
        self.h.advance(5)
        self.assertEqual(pkg.members[1].state, "holding")
        self.h.advance(120)
        self.assertFalse(pkg.pushed)                  # still waiting for the player
        self.move_player(20000 + 10 * NM + 1000)     # at the IP (10 nm east of Red Front)
        self.h.advance(5)
        self.assertEqual(pkg.players[PLAYER].state, "at_ip")
        self.assertIn("at the IP, hold", self.texts()[-1])
        self.h.advance(65)
        self.assertTrue(pkg.pushed)
        self.assertEqual(pkg.players[PLAYER].state, "pushed")
        self.assertTrue(any("Anvil, PUSH PUSH" in t for t in self.texts()))

    def test_player_calls_the_push(self):
        pkg = self.blue_package()
        self.menu("AI Packages/Join/Package 1")
        self.menu("AI Packages/Push now")
        self.assertTrue(pkg.pushed)
        self.assertTrue(any("called by Ivan" in t for t in self.texts()))

    def test_countdown_and_leave(self):
        pkg = self.blue_package(pushInMin=10, pushWhenReady=False)
        self.menu("AI Packages/Join/Package 1")
        self.h.advance(5 * 60 + 10)
        self.assertTrue(any("push in 5 minutes" in t for t in self.texts()))
        self.menu("AI Packages/Leave package")
        self.assertEqual(pkg.players[PLAYER].state, "left")
        self.assertEqual(len([m for m in (self.g.STUB.marks or {}).values()]), 0)

    def test_player_leaving_the_slot_leaves_the_package(self):
        pkg = self.blue_package()
        self.menu("AI Packages/Join/Package 1")
        self.player.destroy(self.player)
        self.h.advance(5)
        self.assertEqual(pkg.players[PLAYER].state, "left")

    def test_request_support_reaches_the_commander(self):
        self.menu("AI Packages/Request support/SEAD")
        req = [e for e in self.x.events.blue.values() if e.kind == "player_request"]
        self.assertEqual(req[0].wants, "sead")
        self.assertEqual(req[0].nearestEnemyZone, "Red Front")
        self.assertTrue(self.x.eventPending.blue)
        self.menu("AI Packages/Request support/CAS")
        self.assertIn("we have your request", self.texts()[-1])


class NaturalLanguageWingmanTest(Phase5Base):
    def setUp(self):
        super().setUp()
        self.W = self.g.FootholdAI.wingman
        self.wg = self.g.STUB.makeGroup("WM-1", 0, 2, self.lua.table_from([self.lua.table_from({
            "name": "wm-u1", "type": "F-16C_50", "p": self.lua.table_from({"x": 54800, "y": 6000, "z": 100})})]))
        self.W.flights[PLAYER] = self.lua.table_from({"playerGroupName": PLAYER, "playerUnitName": "viper-1",
                                                      "groupName": "WM-1", "cat": "plane", "count": 1, "side": 2,
                                                      "mode": "follow"})
        self.W.byWingmanGroup["WM-1"] = PLAYER

    def mark(self, text, x=21000, idx=7):
        self.g.STUB.fire(self.lua.table_from({"id": 25, "idx": idx, "text": text, "coalition": 2,
                                              "pos": self.lua.table_from({"x": x, "y": 0, "z": 0}),
                                              "initiator": self.player.units[1]}))

    def state(self):
        return json.loads((self.exchange / "state_blue_wingman.json").read_text(encoding="utf-8"))

    def answer(self, results):
        st = self.state()
        sidecar.write_orders(self.exchange, "blue", {"schema": sidecar.ORDERS_SCHEMA, "side": "blue", "seq": 99,
                                                     "session": st["session"], "kind": "wingman",
                                                     "results": results})
        self.h.advance(5)

    def test_mark_order_goes_to_claude_with_context_and_is_carried_out(self):
        self.mark("wm Attack the SAM at Red Front")
        req = self.state()["payload"]["requests"][0]
        self.assertEqual(req["text"], "attack the sam at red front")
        self.assertEqual(req["player"]["type"], "F-16C_50")
        self.assertEqual(req["mark"]["distanceNm"], round(34000 / NM))
        self.assertIn("Red Front", [z["name"] for z in req["zones"]])
        self.assertEqual(req["wingmen"]["mode"], "follow")
        self.answer([{"id": req["id"], "reply": "Two, engaging SAMs at Red Front.",
                      "actions": [{"action": "attack", "kind": "air_defence", "where": "zone", "zone": "Red Front"}]}])
        task = self.wg.controller.task
        self.assertEqual(task.id, "ComboTask")
        engage = task.params.tasks[1].params
        self.assertEqual((engage.point.x, engage.targetTypes[1]), (20000, "Air Defence"))
        self.assertTrue(any("Wingman: Two, engaging SAMs at Red Front." in t for t in self.texts()))
        self.assertEqual(len(list(self.W.nl.pending.keys())), 0)

    def test_plain_wm_mark_is_still_a_target_mark(self):
        self.mark("wm")
        self.assertFalse((self.exchange / "state_blue_wingman.json").exists())

    def test_attack_at_mark_and_weapons_hold(self):
        self.mark("wm hit the trucks here", x=30000)
        req = self.state()["payload"]["requests"][0]
        self.answer([{"id": req["id"], "reply": "Two.", "actions": [
            {"action": "attack", "kind": "ground", "where": "mark", "radius_nm": 50},
            {"action": "weapons", "free": False}]}])
        engage = self.wg.controller.task.params.tasks[1].params
        self.assertEqual(engage.point.x, 30000)
        self.assertEqual(engage.zoneRadius, 20 * NM)   # radius capped
        self.assertEqual(self.wg.controller.options[0], 4)

    def test_unanswered_request_times_out(self):
        self.mark("wm status")
        self.h.advance(95)
        self.assertTrue(any("no answer" in t for t in self.texts()))

    def test_chat_inbox_lines_become_requests(self):
        self.h.advance(2)   # first poll: no inbox yet
        (self.exchange / "chat_inbox.lua").write_text(
            'return { items = {\n\t{ seq = 5, name = "Ivan", text = "wm hold over Red Front" },\n'
            '\t{ seq = 6, name = "Someone", text = "hello" },\n} }\n', encoding="utf-8")
        self.h.advance(2)
        reqs = self.state()["payload"]["requests"]
        self.assertEqual([r["text"] for r in reqs], ["hold over Red Front"])


class SidecarWingmanTest(unittest.TestCase):
    class Fake:
        def __init__(self):
            self.calls = []

        def call(self, prompt, schema, system_prompt_file=None, effort=None, model=None):
            self.calls.append({"prompt": prompt, "model": model, "effort": effort})
            return {"output": {"reply": "Two, engaging.", "actions": [
                {"action": "attack", "kind": "air_defence", "where": "zone", "zone": "Delta"},
                {"action": "join"},
                {"action": "hold", "where": "zone", "zone": "Nowhere"}]}, "latency_ms": 3000, "models": []}

    def test_answers_each_request_once_and_cleans_actions(self):
        with tempfile.TemporaryDirectory() as tmp:
            bridge = sidecar.Bridge(pathlib.Path(tmp), None)
            bridge.claude = self.Fake()
            req = {"id": "blue-1", "text": "kill the sam at delta then come back",
                   "zones": [{"name": "Delta", "side": "red", "bearingDeg": 10, "distanceNm": 20}]}
            state = {"session": "s1", "payload": {"requests": [req]}}
            out = bridge.on_wingman("blue", state)
            self.assertEqual(out["results"][0]["actions"],
                             [{"action": "attack", "kind": "air_defence", "where": "zone", "zone": "Delta"}])
            self.assertEqual(bridge.claude.calls[0]["model"], "sonnet")
            self.assertIn("kill the sam at delta", bridge.claude.calls[0]["prompt"])
            self.assertIsNone(bridge.on_wingman("blue", state))   # already answered
            bridge.pool.shutdown()


if __name__ == "__main__":
    unittest.main()
