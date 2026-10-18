# Foothold AI – setup and testing

Batch 1 contains the foundation (the mission ↔ Claude bridge) and the AI wingman.
Batch 2 puts Claude **in command** of RED and BLUE: Foothold's own AI commander is off for those sides,
and Claude plans every few minutes through game tools while its standing orders handle instant reactions.
Batch 3 adds the credit economy and RED's player-like operations (deploy forces, exact upgrades, fire missions,
helicopter raids, air assault, ambushes, jamming, AWACS, airlift).
The overall plan is in [PLAN.md](PLAN.md); credits and prices are explained in [ECONOMY.md](ECONOMY.md).

## Files

| File | What it is |
|---|---|
| `Common Scripts/Foothold_AI_Core.lua` | Config, logging, the mailbox shared with the sidecar, and the link test |
| `Common Scripts/Foothold_AI_Wingman.lua` | F10 "AI Wingman" menu |
| `Common Scripts/Foothold_AI_Command.lua` | Takeover of Foothold's AI decisions, order executor, standing orders, snapshots, credits |
| `Common Scripts/Foothold_AI_Ops.lua` | RED operations and the range-checked jamming for both sides |
| `tools/foothold_ai/agent.py` | Runs one Claude planning cycle per side (memory, personality, logs) |
| `tools/foothold_ai/mcp_server.py` | The game tools Claude uses (query the situation, issue orders) |
| `tools/foothold_ai/prompts/command_*.md` | System prompts for the RED commander and BLUE HQ (edit freely) |
| `tools/foothold_ai/patch_miz.py` | Embeds the scripts in a `.miz` and adds the "Foothold AI" trigger |
| `tools/foothold_ai/sidecar.py` | Bridge between DCS and your local Claude Code (stdlib Python) |
| `tools/foothold_ai/tests/` | Offline tests (`pip install lupa`, then `python -m unittest discover -s tools/foothold_ai/tests`) |

## One-time setup (Windows)

1. **Claude Code CLI.** In a terminal run:
   ```
   claude --version
   claude --help | findstr "mcp-config permission-mode json-schema"
   ```
   All three flags must be listed; if not, update Claude Code (checked on 2.1.302). The native installer (`claude.exe`) is recommended over the npm `claude.cmd` wrapper.
2. **Check the sidecar can reach Claude** (no DCS needed):
   ```
   python tools\foothold_ai\sidecar.py --check
   ```
   Expected: `Claude link test ok: ack='link ok' latency=... ms`.
3. **MissionScripting.** Foothold already needs `io` and `lfs` desanitized in `DCS\Scripts\MissionScripting.lua`, and nothing else is needed.
4. **Patch the mission:**
   ```
   python tools\foothold_ai\patch_miz.py "Missions\Foothold_PG_5.3.5_multi_Language_Coldwar-Modern_Vietnam.miz"
   ```
   This writes `..._AI.miz` next to it and leaves the original untouched. Copy that file to your DCS missions folder. Run the same command again after updating the Lua files.

## Running

1. Start the sidecar and leave it running:
   ```
   python tools\foothold_ai\sidecar.py
   ```
   It finds `%USERPROFILE%\Saved Games\DCS` (or `DCS.openbeta`); use `--saved-games <path>` otherwise.
   Exchange files and `sidecar.log` live in `Saved Games\DCS\Missions\Saves\FootholdAI\`.
   Planning cycles use `--cycle-effort medium` (`high` thinks longer) and stop after `--cycle-timeout 600` seconds;
   orders queued before a timeout are still sent.
2. Host the `_AI.miz` from the game as usual.

Optional config: create `Saved Games\DCS\Missions\Saves\FootholdAI\FootholdAI_Config.lua`:
```lua
return {
    debug = true,
    wingman = {
        maxWingmen = 3,
        typeOverride = {
            -- ["C-130J-30"] = false,                                   -- no wingmen for this type
            -- ["AJS37"] = { template = "BLUE_F4E_CAS_AGM65Dx6_GBU12x2_PAVESPIKE_2SHIP" },
        },
    },
}
```

## Test batch 1 checklist

Send back `Saved Games\DCS\Logs\dcs.log`, `...\FootholdAI\sidecar.log`, and a short note for each item.

**Bridge**
- [ ] `dcs.log` contains `[FootholdAI][core] version 0.1.0` and `[FootholdAI][wingman] ready`, about 20 s after mission start.
- [ ] About 10–20 s later: `[FootholdAI][bridge] link ok side=red ...` and `side=blue`.
- [ ] No Lua errors that mention `Foothold_AI`.

**Wingman** (Persian Gulf, in the air, in a BLUE slot). For each aircraft type you fly, test:
- [ ] F10 › AI Wingman › Request › One wingman: it spawns behind-right and joins up.
- [ ] Formation › Cover me: it engages enemy aircraft.
- [ ] Attack › Ground targets near me (fly near an enemy zone): it attacks, then rejoins after 10 min or on Join up.
- [ ] Attack › Air defences near me / Ships near me.
- [ ] Place an F10 map mark with text `wm` near targets, then Attack › My "wm" map mark.
- [ ] Weapons › Weapons hold / Weapons free.
- [ ] Status shows fuel and weapons.
- [ ] RTB: it lands at the nearest friendly airfield and disappears about 60 s after landing.
- [ ] Dismiss: it disappears.
- [ ] Die or leave the slot while it's with you: it RTBs.
- [ ] Request › Three wingmen: a 4-ship forms up.

Note which aircraft types failed to spawn or behaved oddly, e.g. never engaged ground targets. Those go into `typeOverride`.

## Test batch 2 checklist (Claude in command)

Re-patch the mission first (the commander file changed). The sidecar must be running.

**Takeover**
- [ ] `dcs.log`: `[FootholdAI][command] Claude commands: blue,red (Foothold Director decisions off for these sides)`, and no `hook skipped` warnings.
- [ ] Before Claude's first cycle, no RED or BLUE AI flights or attacks launch (supply flights and anything you buy in the shop still do).

**Cycles**
- [ ] About 1 minute after the Director is ready: `red snapshot seq=... reason=start` (and blue).
- [ ] `sidecar.log`: `red: cycle 1 done in N s, M orders` (it took about 30–60 s in testing).
- [ ] `dcs.log`: `red order r1-c1 executed ...` lines; rejected orders show the reason.
- [ ] Every 5 minutes a new cycle (`reason=cycle`); after a zone changes hands or a standing order fires, an extra one (`reason=event`).
- [ ] BLUE: `HQ: ...` messages, and player missions (CAS, SEAD, ...) only for zones HQ designated.

**In the air**
- [ ] Claude's launches appear as AI flights from the ordered origin to the ordered target.
- [ ] Timed packages: SEAD and strike ordered with `delay_min` arrive close together.
- [ ] Standing orders: fly toward a RED zone with a scramble rule and RED CAP launches without waiting for a cycle (`standing order ... executed`).
- [ ] Anything launching that Claude did **not** order (no matching `order ... executed` line) is a gap in the takeover. Please note what and where.

**Send back:** `dcs.log`, `sidecar.log`, `command_red.log` / `command_blue.log` (every cycle's summary and orders), `memory_*_red.json` / `memory_*_blue.json`, and the `cycles\` folder (last snapshot and orders per side).

**Settings** (`FootholdAI_Config.lua`, under `command = { ... }`): `sides` (`{ 'red', 'blue' }`, or one side only), `cycleSec` (300), `eventMinGapSec` (90), `priceScale` (1), `maxStandingOrders` (12).
To change a campaign's personality, edit or delete its `memory_*_<side>.json` file.

## Test batch 3 checklist (credits and RED operations)

Re-patch the mission (a new file, `Foothold_AI_Ops.lua`, is added to the trigger).

**Start**
- [ ] `dcs.log`: `[FootholdAI][ops] RED operations ready (jammer: AN-30M)` (or `ewAircraftRed` if you added one, see [ECONOMY.md](ECONOMY.md)).

**Credits**
- [ ] `command_red.log` / `cycles\red_state.json`: `economy` shows credits, income per minute and a `ledger`.
- [ ] Kill a few things with RED AI (or let it kill you): ground kills appear in the ledger at once; a RED fighter's kills appear when it lands (`kills paid on landing`).
- [ ] RED orders that cost credits are refused with `not enough credits` when RED is broke.

**Operations.** For each one RED Claude orders, note whether it looked right in the game:
- [ ] `deploy_forces`: an extra group appears inside the RED zone. Restart the mission: it is still there (`restored N deployed RED groups`).
- [ ] `upgrade_zone`: the zone gets that exact template (e.g. an SA-11), with the usual "reinforced" message.
- [ ] `fire_mission`: a launcher battery appears in the origin zone and fires about 1 min later (`fire_mission ... fired` in the next snapshot's events). **Check the missiles reach**: the snapshot ranges are my estimates.
- [ ] `heli_raid`: a Mi-8 flies out, lands short of a BLUE zone, unloads a gun that shells the zone, then flies home and disappears on landing.
- [ ] `air_assault`: a Mi-8 lands troops in a neutral zone and the capture countdown starts.
- [ ] `ambush`: a Mi-8 drops an Igla or ZU-23 team between two zones.
- [ ] `jam`: the jammer flies to an orbit about 25 nm from the BLUE zone. Only radars within 40 nm stop firing; shooting it down restores them within 10 s.
- [ ] BLUE shop jammer (if your mission sells it): the jammer now flies toward the target zone, and only jams within 40 nm.
- [ ] `move_awacs`: the RED AWACS moves and stays there after zone captures.

**Send back** the same files as batch 2, plus `ops_*.lua` from the exchange folder.

## Known limitations (batch 1)
- Menu text is English only. Foothold's localization will be added once the feature set settles.
- Wingmen carry the slot's default loadout from the Mission Editor, not what you rearmed to.
- Dismiss removes the aircraft instantly.

## Known limitations (batch 3)
- Fire-mission and raid-gun ranges are estimates (Scud 280 km, Iskander 450 km, Smerch 65 km, 2S9 Nona 8 km, 2S3 Akatsia 17 km); tune them in `command.ops` after testing.
- Deployed forces fight but do not count as zone defenders for capture; `upgrade_zone` is the permanent option.
- Helicopters air-start over their origin zone (no ground start or parking) and are removed when they land back home.
- A gun or ambush team left behind is removed after 30 / 60 minutes (treated as extracted).
- Only `deploy_forces` survives a mission restart; flights, batteries and teams in progress are lost on restart.

## Known limitations (batch 2)
- Claude sets timing with launch delays. Foothold flights have no shared push point yet (phase 4), so arrival times can drift with start-up and taxi.
- Group size and loadout come from the mission's templates; Claude chooses what, where and when, not the airframes.
- RED sees BLUE aircraft only through its radars (Foothold's EWRS registry); BLUE FARPs and ground units are not reported yet.
- If the sidecar stops, nothing on the Claude sides acts (no fallback, by design) until it is running again.
- Player strike missions from Foothold's event scheduler (e.g. the warehouse and port strikes) are still chosen by Foothold.
