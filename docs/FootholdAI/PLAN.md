# Foothold AI – plan

An AI layer for Foothold: Claude (Opus, through the local Claude Code subscription) commands
RED and BLUE AI at the strategic and package level, and Lua inside the mission runs everything in real time.
Players also get AI wingmen.

## Decisions (from the project owner)

| Topic | Decision |
|---|---|
| Host | DCS hosted from the game client; Claude Code runs on the same Windows PC |
| Claude access | Local Claude Code CLI with a Max 20x subscription (`claude -p`, model `opus`); no API key |
| First test mission | Persian Gulf (`Foothold_PG_5.3.5_...miz`, setup `foothold pg nya v2.lua`) |
| Integration | New `Foothold_AI_*.lua` files, loaded by a trigger that `tools/foothold_ai/patch_miz.py` adds. **No edits to `zoneCommanderv2.lua`** |
| Wingman | Air-start next to the player, same aircraft type as the player, free while testing |
| LLM sides | RED and BLUE AI |
| Fog of war | Zone ownership and strength are public; enemy aircraft, FARPs and units are visible only when detected |
| Sidecar | Python 3 (stdlib only) |
| Players | Mostly solo |
| Testing | Batched: the owner runs DCS and sends back `dcs.log` |

## Architecture

```
DCS mission (Lua)                                         Windows PC
┌───────────────────────────────────────────┐            ┌──────────────────────────────┐
│ Foothold (unchanged): Director, BC, CTLD  │            │ tools/foothold_ai/sidecar.py │
│   ▲ wrapped methods (later phases)        │            │  - polls state files         │
│ Foothold_AI_Core.lua                      │  state_*.json  - builds prompt          │
│   - config, log, JSON writer, mailbox ────┼──────────► │  - claude -p --model opus    │
│   - order reader (sandboxed loadfile) ◄───┼─ orders_*.lua    --json-schema …         │
│ Foothold_AI_Wingman.lua (no LLM)          │            │  - writes Lua orders (atomic)│
│ Foothold_AI_Commander.lua (phase 2+)      │            └──────────────────────────────┘
│ Foothold_AI_Actions.lua  (phase 3+)       │
│ Foothold_AI_ATO.lua      (phase 4+)       │
└───────────────────────────────────────────┘
Exchange folder: <Saved Games>\DCS\Missions\Saves\FootholdAI\
```

Rules that apply to every phase:

1. **Claude only picks from options Lua generated.** Lua validates every order against live state and ignores anything invalid.
2. **If Claude is unavailable, Foothold plays exactly as today.** Every hook falls back to the original method.
3. **Nothing in the sim waits on Claude.** Reactions (scrambles, CAP revectors, SEAD reactions) stay in Lua.
4. **Mission Lua uses only `io` and `lfs`.** Foothold already needs both; `os` is not used.

## Phases

### Phase 0 – foundation (this batch)
- `Foothold_AI_Core.lua`: config defaults plus an optional external config, logging, a JSON encoder, the mailbox (state out, orders in), and a link test (ping/pong).
- `tools/foothold_ai/sidecar.py`: polls the state files, calls `claude -p`, and writes orders atomically.
- `tools/foothold_ai/patch_miz.py`: embeds the scripts in a `.miz`, adds a "Foothold AI" trigger after AIEN, and verifies the result.

**Test:** the mission loads without Lua errors. The sidecar log shows a ping, a Claude call and a pong. `dcs.log` shows `link ok` with the round-trip time.

### Phase 1 – AI wingman (this batch, no LLM)
- Adds an F10 "AI Wingman" menu for players in an airplane or helicopter slot.
- **Request:** 1 or 3 wingmen. Each is a copy of the player's own slot template (same type, default loadout, livery), air-started behind the player. Only available when the player is airborne.
- **Commands:** join up, cover me (engage air), attack ground near me, attack air defences near me, attack ships near me, attack my map mark (`wm` marker), weapons free/hold, hold here, status, RTB, dismiss.
- **Lifecycle:** the wingman RTBs when the player dies or leaves the slot, is removed after landing, and is cleaned up when dead.

**Test:** spawn in each player type you care about. Record which types AI can actually fly, then fill `FootholdAI.config.wingman.typeOverride`.

### Phase 2 – snapshot + Claude commander (RED, then BLUE)
- A fog-of-war state snapshot per side: zones, ownership, strength, connections, credits/income, current Director operation, detected enemy air/FARPs, and recent outcomes.
- The commander's decisions are campaign strategy, target area, doctrine, budget priority and CAP/QRA posture. They're applied by wrapping `Director:_selectCampaignStrategy`, `_areaFirstCandidateOrder`, `_pickDoctrine`, `_strategicBudgetDecision` and `rankCapZones`, always falling back to the original.
- Variety: Claude returns 2–3 weighted options and Lua rolls between them. A commander personality is picked per campaign. Play memory is saved alongside Foothold's own save files.

### Phase 3 – RED player-like actions
- `REINFORCE`: extra armor, AAA or SHORAD for a zone, placed on clear ground, delivered and saved across restarts.
- `BUILD_FARP`: a side-aware version of `BuildAFARP` (today it is hard-coded to the BLUE side and USA country), with site selection, saving, and use as a launch point.
- `ARTY_RAID`: a helo carries artillery (simulated) to a landing zone in range, it fires with `AUFTRAG:NewARTY`, then it is extracted.
- `AMBUSH`: a MANPADS team placed on a likely player route.
- A play runner: multi-step plays with pre-checks, timeouts and Claude replans.

### Phase 4 – ATO executor (both sides)
- Packages with a time on target (TOT). Launch times are computed backwards from the TOT, flights hold at the IP until the push time, and use `ETA` on attack waypoints.
- Elements: SEAD, DEAD, strike, anti-ship and escort; several packages can run at once.
- The executor claims aircraft by wrapping `Director:allowsGroupSpawn` / `_canManageGroup`.

### Phase 5 – player integration
- A "Join package" F10 option lets the player take an element slot, and the AI holds at the IP until the shared push time.
- Optional: natural-language wingman commands through a GameGUI hook for chat, and SRS voice later.

## Things that must be checked in DCS, not assumed

| Item | Why |
|---|---|
| Which player types AI can fly (e.g. `C-130J-30`, `F-14A-135-GR-Early`, `Mirage-F1*`) | Some module types may not fly as AI; the wingman logs a spawn failure and a type override covers it |
| Wingman group `task` | Wingmen keep the slot's main task (CAP, CAS, …). If one never engages ground targets, change the task in `typeOverride` |
| `claude --help` lists `--json-schema` on the Windows install | Checked on Claude Code 2.1.302; older versions may lack it |
| Saved Games path | The sidecar takes `--saved-games`, defaulting to `%USERPROFILE%\Saved Games\DCS` |

## Risks
- DCS AI timing and behaviour (TOT accuracy, taxi, engaging).
- Conflicts with Foothold upstream updates. Mitigation: separate files and wrapped methods, no edits to `zoneCommanderv2.lua`.
- Unit count and performance. Mitigation: unit budgets in config.
