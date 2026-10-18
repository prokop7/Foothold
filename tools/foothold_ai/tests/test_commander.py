"""Offline tests for the commander: snapshot, sidecar round trip and Director hooks."""

from __future__ import annotations

import json
import pathlib
import sys
import tempfile
import unittest

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent))

import commander  # noqa: E402
import sidecar  # noqa: E402
from test_foothold_ai import LuaHarness, lua51  # noqa: E402


class PlanClaude:
    """Returns fixed plans and records the schema and prompt it was given."""

    def __init__(self, plans_by_side):
        self.plans_by_side = plans_by_side
        self.calls = []

    def call(self, prompt, schema, system_prompt_file=None, effort=None):
        self.calls.append({"prompt": prompt, "schema": schema, "system": system_prompt_file, "effort": effort})
        side = "red" if "Side: RED" in prompt else "blue"
        return {"output": {"summary": f"{side} intent", "plans": self.plans_by_side[side]},
                "latency_ms": 2000, "models": ["claude-opus-5-5"]}


RED_PLAN = {
    "name": "Hammer east", "weight": 1.0, "rationale": "Base is weak.",
    "strategy": "air_supremacy", "strategyGoal": "Blue Base",
    "focusZones": [{"zone": "Blue Base", "weight": 3}, {"zone": "Red Front", "weight": 4}],
    "avoidZones": ["Blue Front", "Nowhere"],
    "reinforceZones": ["Red Front", "Blue Base"],
    "capZones": ["Red Front"],
    "doctrineWeights": {"suppression": 2, "isolation": 9, "ground_push": 1, "counterattack": 1,
                        "air_assault": 0.5, "probe": 0.01},
    "budgetWeights": {"upgrade": 0.5, "warehouse": 4, "warehouse_repair": 1, "mass_attack": 1, "bomber": 1},
}
BLUE_PLAN = {
    "name": "Support players", "weight": 1.0, "rationale": "Clear the front.",
    "focusZones": [{"zone": "Red Front", "weight": 2}],
    "avoidZones": ["Red Base"],
    "capZones": ["Blue Front"],
}


@unittest.skipIf(lua51 is None, "lupa not installed")
class CommanderTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.saved = pathlib.Path(self.tmp.name)
        self.h = LuaHarness(self.saved)
        self.h.lua.execute((HERE / "foothold_stub.lua").read_text(encoding="utf-8"))
        self.h.lua.execute("FootholdAIConfig = { wingman = { enabled = false } }")
        self.h.load_script("Foothold_AI_Core.lua")
        self.h.load_script("Foothold_AI_Commander.lua")
        self.exchange = self.saved / "Missions" / "Saves" / "FootholdAI"
        self.fs = self.h.g.FS
        self.claude = PlanClaude({"red": [RED_PLAN], "blue": [BLUE_PLAN]})
        self.bridge = sidecar.Bridge(self.exchange, self.claude)

    def tearDown(self):
        self.bridge.pool.shutdown(wait=True)
        self.tmp.cleanup()

    def request_and_answer(self):
        self.h.advance(160)  # first tick marks ready, request after firstRequestSec
        for side in sidecar.SIDES:
            state = self.bridge.read_state(side, "commander")
            self.assertIsNotNone(state, side)
            self.bridge.handle(side, state)
        self.h.advance(5)

    def state(self, side):
        return json.loads((self.exchange / f"state_{side}_commander.json").read_text(encoding="utf-8"))

    def test_snapshot_contents_and_fog_of_war(self):
        self.h.advance(160)
        red = self.state("red")["payload"]
        names = {z["name"] for z in red["zones"]}
        self.assertNotIn("Hidden Zone", names)
        front = next(z for z in red["zones"] if z["name"] == "Red Front")
        self.assertTrue(front["frontline"])
        self.assertEqual(front["groups"], 4)
        self.assertEqual(front["maxGroups"], 6)
        self.assertEqual(red["economy"]["credits"], 1200)
        self.assertEqual(red["detectedEnemyAir"][0]["type"], "FA-18C_hornet")
        self.assertEqual(red["detectedEnemyAir"][0]["nearZone"], "Blue Front")
        self.assertNotIn("friendlyPlayers", red)
        self.assertEqual(red["campaignStrategy"]["name"], "breakthrough")
        self.assertEqual(red["currentOperation"]["target"], "Blue Front")
        self.assertEqual(red["targetCandidates"][0]["zone"], "Blue Front")
        self.assertEqual(red["recentZoneChanges"][0]["to"], "blue")
        self.assertIn("isolation", red["menu"]["doctrines"])
        blue = self.state("blue")["payload"]
        self.assertEqual(blue["detectedEnemyAir"], [])
        self.assertIn("friendlyPlayers", blue)
        self.assertNotIn("menu", {k for k, v in blue.items() if v})

    def test_schema_restricts_zones_to_state(self):
        self.request_and_answer()
        red_call = next(c for c in self.claude.calls if "Side: RED" in c["prompt"])
        plan = red_call["schema"]["properties"]["plans"]["items"]["properties"]
        self.assertEqual(plan["focusZones"]["items"]["properties"]["zone"]["enum"],
                         ["Blue Base", "Blue Front", "Neutral Hill"])
        self.assertEqual(plan["reinforceZones"]["items"]["enum"], ["Red Base", "Red Front"])
        self.assertIn("keep", plan["strategy"]["enum"])
        self.assertEqual(red_call["effort"], "high")
        self.assertTrue(str(red_call["system"]).endswith("commander_red.md"))

    def test_red_plan_validation_and_strategy(self):
        self.request_and_answer()
        plan = self.h.g.FootholdAI.commander.plans.red
        self.assertEqual(plan.name, "Hammer east")
        self.assertEqual(list(plan.focusList.values()), ["Blue Base"])  # own zone dropped
        self.assertIsNone(plan.focus["Red Front"])
        self.assertTrue(plan.avoid["Blue Front"])
        self.assertIsNone(plan.avoid["Nowhere"])
        self.assertEqual(plan.doctrineWeights.isolation, 4)     # clamped
        self.assertEqual(plan.doctrineWeights.probe, 0.25)      # clamped
        self.assertIsNotNone(plan.reinforce["Red Front"])
        self.assertIsNone(plan.reinforce["Blue Base"])          # enemy zone dropped
        strategy = self.fs.red.campaignStrategy
        self.assertEqual(strategy.name, "air_supremacy")
        self.assertEqual(strategy.goalZone, "Blue Base")
        self.assertEqual(strategy.goalRegion, "region-east")

    def test_red_hooks(self):
        self.request_and_answer()
        red = self.fs.red
        candidates = red._collectTargetCandidates(red, 0)
        self.assertEqual(candidates[1].zone.zone, "Blue Base")          # 40 * 3 = 120
        self.assertAlmostEqual(candidates[len(candidates)].score, 10.0)  # Blue Front 50 * 0.2

        ranked_before = red.areaShadowRecommendation.ranked
        preferred, _, area = red._areaFirstCandidateOrder(red, candidates)
        self.assertEqual(area, "east")
        same = self.h.lua.eval("function(a, b) return rawequal(a, b) end")
        self.assertTrue(same(red.areaShadowRecommendation.ranked, ranked_before))  # restored

        self.assertEqual(red._doctrineSelectionWeight(red, "isolation"), 12)
        self.assertEqual(red._doctrineSelectionWeight(red, "probe"), 0.25)

        budget = red._strategicBudgetCandidates(red, 0, 0, None)
        self.assertEqual(budget[1].action, "warehouse")  # 100 * 4 beats 300 * 0.5

        zone = self.fs.byName["Red Front"]
        self.assertGreater(red._zoneUpgradeScore(red, zone, None, 0), 10)
        self.assertEqual(red._zoneUpgradeScore(red, self.fs.byName["Red Base"], None, 0), 10)

        cache = red.rankCapZones(red, "patrol", None)
        self.assertEqual(cache[1].zone, "Red Front")
        self.assertEqual(red.capCache[1].zone, "Red Base")  # Director cache untouched

    def test_blue_hooks_and_announcement(self):
        self.request_and_answer()
        blue = self.fs.blue
        score = blue._blueMissionCandidateScore
        self.assertEqual(score(blue, None, "CAS", None, 0, self.fs.byName["Red Front"]), 400)
        self.assertEqual(score(blue, None, "CAS", None, 0, self.fs.byName["Red Base"]), 20)
        self.assertEqual(score(blue, None, "CAS", None, 0, self.fs.byName["Neutral Hill"]), 100)
        cap = blue.rankCapZones(blue, "patrol", None)
        self.assertEqual(cap[1].zone, "Blue Front")
        self.assertEqual(blue.capCache[1].zone, "Blue Base")
        texts = [t.text for t in self.h.g.STUB.coalitionTexts.values()]
        self.assertIn("HQ intent: blue intent", texts)

    def test_no_plan_or_expired_plan_is_neutral(self):
        red = self.fs.red
        self.assertEqual(red._doctrineSelectionWeight(red, "isolation"), 3)
        self.request_and_answer()
        self.assertEqual(red._doctrineSelectionWeight(red, "isolation"), 12)
        self.h.advance(1800)
        self.assertEqual(red._doctrineSelectionWeight(red, "isolation"), 3)

    def test_hook_error_falls_back_to_original(self):
        self.request_and_answer()
        red = self.fs.red
        self.fs.injectBroken = True
        candidates = red._collectTargetCandidates(red, 0)
        scores = {c.zone.zone if c.zone else None: c.score for c in candidates.values()}
        self.assertEqual(scores["Blue Base"], 40)  # unbiased: original result kept intact
        self.assertEqual(scores["Blue Front"], 50)
        warnings = [l for l in self.h.logs() if "hook _collectTargetCandidates failed" in l]
        self.assertEqual(len(warnings), 1)
        red._collectTargetCandidates(red, 0)
        warnings = [l for l in self.h.logs() if "hook _collectTargetCandidates failed" in l]
        self.assertEqual(len(warnings), 1)  # logged once

    def test_ownership_change_triggers_early_replan(self):
        self.request_and_answer()
        first = self.state("red")["seq"]
        self.h.lua.eval("function() return Director:recordZoneOwnershipChange('Neutral Hill', 0, 1, 0) end")()
        self.h.advance(200)
        self.assertEqual(self.state("red")["seq"], first)  # eventMinIntervalSec not reached yet
        self.h.advance(60)
        st = self.state("red")
        self.assertGreater(st["seq"], first)
        self.assertEqual(st["payload"]["reason"], "zone-change")
        self.assertEqual(st["payload"]["currentPlan"]["name"], "Hammer east")

    def test_operation_outcome_recorded(self):
        red = self.fs.red
        red._finishOperation(red, "captured", 0)
        self.assertIsNone(red.operation)
        self.h.advance(160)
        ops = self.state("red")["payload"]["recentOperations"]
        self.assertEqual(ops[0], {"target": "Blue Front", "doctrine": "probe", "result": "captured",
                                  "minuteFinished": 500})

    def test_memory_and_logs_written(self):
        self.request_and_answer()
        memory_files = list(self.exchange.glob("memory_*.json"))
        self.assertEqual(len(memory_files), 1)
        memory = json.loads(memory_files[0].read_text(encoding="utf-8"))
        self.assertIn(memory["personality"]["red"], commander.PERSONALITIES["red"])
        self.assertEqual(memory["history"]["red"][0]["plans"][0]["name"], "Hammer east")
        self.assertTrue((self.exchange / "commander_red.log").exists())


class SchemaTest(unittest.TestCase):
    def test_keep_strategy_is_dropped(self):
        out = commander.sanitize("red", {"summary": "x", "plans": [dict(RED_PLAN, strategy="keep")]})
        self.assertNotIn("strategy", out["plans"][0])

    def test_plan_count_and_weight_clamped(self):
        plans = [dict(BLUE_PLAN, weight=w) for w in (50, -1, 1, 1)]
        out = commander.sanitize("blue", {"summary": "x", "plans": plans})
        self.assertEqual(len(out["plans"]), 3)
        self.assertEqual(out["plans"][0]["weight"], 10.0)
        self.assertEqual(out["plans"][1]["weight"], 0.05)


if __name__ == "__main__":
    unittest.main()
