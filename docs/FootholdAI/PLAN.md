# Foothold AI – plan

Claude (Opus, through the local Claude Code subscription) **commands** RED and BLUE. Foothold's own AI commander is switched off for those sides, and Foothold's scripts only carry out Claude's orders: spawning, routing, warehouses, supply, saving. Instant reactions between planning cycles come from standing orders that Claude writes and Lua runs. Players also get AI wingmen.

## Decisions (from the project owner)

| Topic | Decision |
|---|---|
| Host | DCS hosted from the game client; Claude Code runs on the same Windows PC |
| Claude access | Local Claude Code CLI with a Max 20x subscription (`claude -p`, model `opus`); no API key |
| First test mission | Persian Gulf (`Foothold_PG_5.3.5_...miz`, setup `foothold pg nya v2.lua`) |
| Integration | New `Foothold_AI_*.lua` files, loaded by a trigger that `tools/foothold_ai/patch_miz.py` adds. **No edits to `zoneCommanderv2.lua`** |
| Who decides | **Claude decides everything** for its sides; Foothold's Director decisions are off; **no fallback** |
| Assets | Foothold's pre-built capabilities **and** free-form missions (any own origin, role and target), priced from the Foothold shop |
| Reactions | Both: instant standing orders run by Lua, and thoughtful package planning by Claude each cycle |
| Supply | Claude sets priorities; the existing dispatcher flies routine runs; Claude can order extra runs |
| BLUE player tasking | Claude HQ picks the zones offered to players per role |
| Cadence | A planning cycle every 5 minutes per side, plus extra cycles after events |
| How Claude works | Autonomous agent with game tools (MCP); it cannot ask the user questions |
| Wingman | Air-start next to the player, same aircraft type as the player, free while testing |
| Fog of war | Zone ownership and strength are public; enemy aircraft only when this side's radars detect them |
| Sidecar | Python 3, standard library only |
| Testing | Batched: the owner runs DCS and sends back logs |

## Architecture

```
DCS mission (Lua)                                    Windows PC
┌──────────────────────────────────────────┐        ┌──────────────────────────────────────────┐
│ Foothold: BattleCommander, Director, CTLD│        │ sidecar.py  (polls state files)          │
│   Director decisions OFF for Claude sides│        │   └ agent.py  one cycle per side:        │
│   (wrapped, see "Takeover")              │        │       claude -p --model opus             │
│ Foothold_AI_Core.lua   mailbox, config   │ state  │         --mcp-config → mcp_server.py     │
│ Foothold_AI_Command.lua                  │───────►│         --tools "" --permission-mode     │
│   snapshot · executor · standing orders  │        │           dontAsk                        │
│   spawn gate · mission tracking          │◄───────│       Claude: get_overview, list_*,      │
│ Foothold_AI_Wingman.lua  (no LLM)        │ orders │       launch_*, purchase, set_*,         │
└──────────────────────────────────────────┘        │       finish_cycle                       │
Exchange folder: <Saved Games>\DCS\Missions\Saves\FootholdAI\                                     │
                                                    └──────────────────────────────────────────┘
```

**One cycle:**
1. Lua builds a snapshot: zones, every own capability with an eligibility check and reason, free-form roles and prices, purchases, missions, radar contacts, events, and the results of earlier orders.
2. The sidecar starts Claude Code headless with the Foothold game tools.
3. Claude inspects the situation, issues orders (each checked immediately by the tool, with a specific error), and calls `finish_cycle` with a summary and notes for its next cycle.
4. The sidecar writes the orders file. Lua executes each order now or after `delaySec`, then reports the results in the next snapshot.

## Takeover (what is switched off for a Claude-commanded side)

| Foothold behaviour | Under Claude |
|---|---|
| Director operations, routine CAP, ground releases, reactions, BLUE assignments | Neutral (wrapped methods return "nothing to do") |
| `Director:allowsGroupSpawn` | Gate: only groups Claude authorized, live groups, supply, player/shop launches and save restores spawn |
| Director budget purchases | Only Claude's `purchase` orders |
| RED reactive system (`_redReactiveTick`) | Off |
| `EventCommander` random RED events | Off; Claude can `trigger_event` |
| Supply dispatcher | Runs, steered by Claude's `supply_priority`; Claude can order `supply_run` |
| BLUE player mission targets (`selectMissionTarget`) | Claude's `player_tasks`; undesignated roles get no missions |
| Player shop, CTLD, AIEN, wingman | Unchanged |

## Orders (Lua executes, using Foothold's own code paths)

| Order | Foothold path |
|---|---|
| `launch_capability` (optional new target for CAP/CAS/SEAD/RUNWAYSTRIKE) | eligibility → `resolveDirectorCandidate` → `_retaskGroupForAssignment` → `_authorizeDirectorOnDemandGroup` |
| `launch_mission` (free-form) | runtime `DirectorCapability` like Foothold's DynamicHybrid (`FAI-<side>-<origin>-<target>-<role>`), then the same launch; costs credits; saved to `freeform_*.lua` and re-registered at start |
| `purchase` (RED: upgrade zone/category, warehouse, repair, mass_attack, bomber) | `Director:_executeStrategicBudgetCandidate` with the zone/category honoured via `selectZoneUpgradeTarget` |
| `supply_priority`, `supply_run` | `_regularSupplyTargetPriority` bonus or starve; `_dispatchRegularSupplyCommander` |
| `player_tasks` (BLUE) | `selectMissionTarget` |
| `trigger_event` (RED) | `evc` scripted events |
| `hq_message` (BLUE) | coalition text |
| `standing_orders` | Lua rules: `enemy_air_near` (EWRS radar contacts), `zone_attacked` (AIEN reports, RED), `zone_lost`; with cooldown, max active, and `$zone` substitution |
| `deploy_forces` (RED) | `CustomZone:spawnGroup` with the mission's own RED zone templates; saved to `ops_*.lua` and respawned at start |
| `upgrade_zone` (RED) | `zone:addExtraSlot(template)` + `zone:upgrade(true)`, the same steps as Foothold's RED zone upgrade |
| `fire_mission` (RED) | Launcher template spawned in the origin zone, then `bc:fireAtZone` |
| `heli_raid`, `air_assault`, `ambush` (RED) | Mi-8 flight with a Land task; on landing: gun + `bc:fireAtZone`, `zone:startPendingCaptureFromAircraft(RED, ...)`, or a MANPADS/AAA team |
| `jam` (RED) | Jammer flight + `bc:jamRadarsAtZone`, which now range-checks for both sides |
| `move_awacs`, `supply_airlift` (RED) | `setAwacsRacetrack` (Claude's station kept over Foothold's re-positioning); `zone:_addExpeditedRegularSupplyStock` |

Every order is paid from the side's Foothold account; RED earns from zones, kills and captures. See [ECONOMY.md](ECONOMY.md).

Denied launches (e.g. runway blocked, origin lost) are cleaned up like the Director's own denials and reported to Claude.

## Phases

| Phase | Content | Status |
|---|---|---|
| 0 | Foundation: core, bridge, patcher, link test | done (batch 1) |
| 1 | AI wingman | done (batch 1) |
| 2 | ~~Bias commander~~ replaced by **Claude command mode** (above) | done (batch 2) |
| 3 | Credit economy and RED player-like operations (waves 1 and 2 of [RED_TOOLKIT.md](RED_TOOLKIT.md)) | done (batch 3) |
| 3b | Wave 3: recon → intel, hunting BLUE FARPs and CTLD sites, RED forward FARPs | planned |
| 4 | Package timing in Lua: IP hold and push time, so packages hit together regardless of start-up delays (today Claude times with `delaySec`) | planned |
| 5 | Player joins AI packages; natural-language wingman | planned |

## Things that must be checked in DCS, not assumed

| Item | Why |
|---|---|
| Which player types AI can fly | Wingman spawn failures are logged; `typeOverride` covers them |
| Wingman group `task` | Some types may need a different main task to engage ground targets |
| `claude --help` lists `--mcp-config`, `--permission-mode` and `--system-prompt-file` | Checked on Claude Code 2.1.302 |
| Saved Games path | `--saved-games` if not `%USERPROFILE%\Saved Games\DCS` |
| Takeover completeness | Look for AI launches Claude did not order (any would mean a Foothold path I have not covered) |
| Persistence | Claude-launched groups in flight when the mission saves and restarts |

## Risks
- Usage limits: two Opus agent cycles every 5 minutes. Each test cycle took about 33 s and 14–16 tool calls. Raise `cycleSec` if limits bite.
- DCS AI timing and behaviour.
- Upstream Foothold changes to the wrapped methods. Mitigation: hooks are listed in one place and log a warning if a method is missing.
