# Foothold AI – setup and test batch 1

Batch 1 contains the foundation (the mission ↔ Claude bridge) and the AI wingman.
The overall plan is in [PLAN.md](PLAN.md).

## Files

| File | What it is |
|---|---|
| `Common Scripts/Foothold_AI_Core.lua` | Config, logging, the mailbox shared with the sidecar, and the link test |
| `Common Scripts/Foothold_AI_Wingman.lua` | F10 "AI Wingman" menu |
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

## Known limitations (batch 1)
- Menu text is English only. Foothold's localization will be added once the feature set settles.
- Wingmen carry the slot's default loadout from the Mission Editor, not what you rearmed to.
- Dismiss removes the aircraft instantly.
