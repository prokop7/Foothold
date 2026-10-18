# Foothold AI – setup and testing

Batch 1 contains the foundation (the mission ↔ Claude bridge) and the AI wingman.
Batch 2 adds the Claude commander for RED and BLUE (phase 2).
The overall plan is in [PLAN.md](PLAN.md).

## Files

| File | What it is |
|---|---|
| `Common Scripts/Foothold_AI_Core.lua` | Config, logging, the mailbox shared with the sidecar, and the link test |
| `Common Scripts/Foothold_AI_Wingman.lua` | F10 "AI Wingman" menu |
| `Common Scripts/Foothold_AI_Commander.lua` | Fog-of-war snapshot, plan validation, Director hooks |
| `tools/foothold_ai/commander.py` | Commander schema, prompt and per-campaign memory (used by the sidecar) |
| `tools/foothold_ai/prompts/commander_*.md` | System prompts for the RED commander and BLUE HQ (edit freely) |
| `tools/foothold_ai/patch_miz.py` | Embeds the scripts in a `.miz` and adds the "Foothold AI" trigger |
| `tools/foothold_ai/sidecar.py` | Bridge between DCS and your local Claude Code (stdlib Python) |
| `tools/foothold_ai/tests/` | Offline tests (`pip install lupa`, then `python -m unittest discover -s tools/foothold_ai/tests`) |

## One-time setup (Windows)

1. **Claude Code CLI.** In a terminal run:
   ```
   claude --version
   claude --help | findstr json-schema
   ```
   The second command must print a `--json-schema` line; if it doesn't, update Claude Code. The native installer (`claude.exe`) is recommended over the npm `claude.cmd` wrapper.
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
   Commander plans use `--commander-effort high` by default (`medium` is faster; `xhigh`/`max` think longer).
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

## Test batch 2 checklist (commander)

The commander needs the sidecar running and Claude reachable (batch 1 bridge items).

- [ ] About 2 minutes after the Director is ready, `dcs.log` shows `[FootholdAI][commander] red requested plan ... reason=start`, and the same for blue.
- [ ] `sidecar.log` shows `commander plans=[...]` for each side, usually within 1–2 minutes.
- [ ] `dcs.log` shows `red picked plan "..." from [...]` and `red strategy=... goal=...`.
- [ ] BLUE players see a `HQ intent: ...` message.
- [ ] Over a longer session: re-plans every 15 minutes (`reason=interval`), and sooner after a zone changes hands (`reason=zone-change`).
- [ ] Does RED behaviour follow the plan? Compare the Director's `operation=... target=...` log lines with the plan's focus zones.
- [ ] No `hook ... failed` warnings. If one appears, Foothold kept its default behaviour; send the log line.

Files to send for batch 2, in addition to `dcs.log` and `sidecar.log`:
- `commander_red.log` and `commander_blue.log` (every plan Claude produced).
- `memory_*.json` (personality and plan history per campaign).
- `state_red_commander.json` / `state_blue_commander.json` (the last snapshot sent).

Commander settings (in `FootholdAI_Config.lua`, under `commander = { ... }`):
`intervalSec` (default 900), `eventMinIntervalSec` (240), `planTtlSec` (1800), `announceBlue` (true), `sides` (`{ 'red', 'blue' }`), and `bias` strengths.
To change a campaign's personality, edit or delete its `memory_*.json` file.

## Known limitations (batch 1)
- Menu text is English only. Foothold's localization will be added once the feature set settles.
- Wingmen carry the slot's default loadout from the Mission Editor, not what you rearmed to.
- Dismiss removes the aircraft instantly.

## Known limitations (batch 2)
- The commander steers priorities only. Foothold's Director still decides whether an operation is possible and which aircraft fly it.
- RED knows BLUE aircraft only from Foothold's EWRS radar registry. BLUE FARPs and ground units are not reported yet (phase 3).
- The plan stops steering 30 min after it was received if no new plan arrives, e.g. when the sidecar is stopped.
