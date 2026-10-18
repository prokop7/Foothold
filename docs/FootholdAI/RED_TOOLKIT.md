# RED toolkit for Claude: what BLUE players can do, and what RED could get

> **Status:** waves 1 and 2 are built (batch 3): `Foothold_AI_Ops.lua`, with prices and the economy in [ECONOMY.md](ECONOMY.md). B2 jamming has the range check for both sides. Wave 3 is not built yet.

This compares BLUE's player toolbox (CTLD and shop) with RED's, and proposes new orders that let Claude play RED the way a capable player team would. Everything below is from the code (Persian Gulf mission, `Foothold CTLD.lua`, `Foothold_CTLD_Red.lua`, `foothold pg nya v2.lua`, `zoneCommanderv2.lua`). The line numbers are from the current branch.

## 1. What BLUE players have today

**CTLD (helicopters and C-130)**
- **Troops:**
  - Squads and platoons of 8, 16 or 32.
  - Mortar team.
  - Engineers (can capture zones when enabled).
  - Zone Spy: 60 minutes of intel on the nearest RED zone.
  - Demolition team: blows up a RED zone's statics.
  - Manpads team.
- **Crates:**
  - Vehicles: Humvee, Bradley, Linebacker, Vulcan, L118, ammo truck.
  - SAM systems built from parts: HAWK, NASAMS, IRIS-T.
  - Modern era only: C-RAM and HIMARS.
- **FARP crates:**
  - Build a working FARP via `BuildAFARP`.
  - It is registered as a BLUE dynamic FARP, saved and restored, and gets its own supply stock.
- **"Zone supplies" crates:**
  - Into a neutral zone: they start a capture.
  - Into a BLUE zone: they add supply stock.
- **Warehouse crates:** move warehouse stock between bases.
- **C-130 auto-build:** an invisible helper unit builds landed crates with no player on the ground (`Foothold CTLD.lua:3151`). This is the pattern for building without a player.

**Shop (BLUE credits)**

| Category | Items |
|---|---|
| AI attack | CAP, CAS, SEAD, TALD decoy, bomber flight, strategic bomber, ground-attack convoy, structure strike, cruise missiles |
| Zone upgrades | Infantry, armor, HAWK, NASAMS, Patriot, Avenger, Roland, Gepard, Vulcan, C-RAM, HIMARS, GCI, a global extra slot |
| JTAC and intel | JTAC drone, 9-line, smoke / flare / illumination, zone intel |
| Combined Arms | Deploy tanks, artillery, recon, air defence, LAV / MGS / Dragoon in a friendly zone |
| Logistics | Capture neutral zone, advance capture (helo assault on a weakened RED zone), resupply, fully upgrade, logistic center, warehouse repair, +3 supplies, +50 warehouse |
| Support | Drogue and boom tankers, FARP at a map marker (a Chinook flies it in) |

## 2. What RED already has with Claude in command
- Launch any of the map's RED capabilities, and retarget CAP/CAS/SEAD/runway strikes.
- Free-form CAP, sweep, CAS, helicopter CAS, SEAD, runway strike, convoy and artillery missions from any RED base.
- Purchases:
  - zone upgrades by category (1 extra slot per zone);
  - depots and depot repair;
  - mass attack;
  - strategic bomber.
- Supply priorities and supply runs (including capture of neutral zones by supply).
- Scripted RED events: Bandar attack, Scuds, helo hunt, tactical airstrike.
- Standing orders: scramble on radar contact, react when attacked, counterattack a lost zone.

**What RED lacks compared to BLUE players:**
- forward bases;
- troop and air-assault capture;
- placing forces outside its zone templates;
- long-range fire missions on demand;
- jamming;
- recon and intel;
- hunting the players' FARPs and CTLD sites.

## 3. Proposed new RED orders

| Effort | Meaning |
|---|---|
| Low | Calls an existing side-generic Foothold function |
| Medium | Adds a small flight or spawn sequence on top of existing functions |
| High | Needs RED-side versions of BLUE-only code |

Prices follow the closest BLUE shop item (`Foothold Config.lua` ShopPrices), scaled by `priceScale`.

### A. Forces on the ground

| # | Order | BLUE counterpart | How in Foothold (verified) | To build | Effort | Price |
|---|---|---|---|---|---|---|
| A1 | **deploy_forces**: armor / AAA / SHORAD / SAM / infantry / artillery group into a RED zone | Combined Arms deploy; zone upgrades | `CustomZone:spawnGroup(template, forceFirst, side, ...)` (zC:4559) spawns in a free sub-zone; the template's ME coalition sets the side. RED templates exist: `Red Armour Group*`, `Red SAM AAA*`, `Red SAM SHORAD SA-8/13/15/19`, `Red SAM SA-6/11`, `Red Arty*`, `Igla`, `Enemy ground forces` | Template catalogue per category/era, caps per zone and in total, our own save/restore (these groups are not in `zone.built`) | Low | armor 1000 (zarm), SHORAD 1000 (zavenger), AAA 500–750 (zvulcan/zgepard), medium SAM 2000 (zhawk), long-range SAM 5000 (zpat), infantry 500 (zinf), MLRS 2500 (zhimars) |
| A2 | **upgrade with exact template** (e.g. SA-11 instead of "a sam") | zhawk / zsam / zpat | `zone:addExtraSlot(template)` (zC:44066, cap 1 for RED, +1 with gslot) then `zone:upgrade(true)`, the same pattern as `redZoneUpgradeAction` (zC:21610-21617) | Template whitelist and price per template | Low | as A1 |
| A3 | **ambush**: MANPADS / ZU-23 team placed on an approach route, outside zones | CTLD AA soldiers / AA crates | SPAWN of `Igla`, `Igla-S`, `Red SAM AAA 9` (tt_ZU-23) at a point | Choosing a point: Claude gives a zone pair and distance, Lua finds clear ground. Delivered by helicopter (A4 machinery) or only near RED zones, so nothing appears out of thin air | Medium | 300–500 |
| A4 | **heli artillery raid**: Mi-8 carries a gun to a landing zone in range of a BLUE zone; it fires, then is extracted | CTLD L118 / mortar crates | Mi-8 template `RED_MI8_SUPPLY_KORD`; RED CTLD gun templates `CTLD_CARGO_RED_ARTY_Nona` / `_Akatsia`; firing via `bc:fireAtZone(zone, group, precise, n)` (zC:22393, side-generic, already used by the Scud event) | Flight → land → spawn gun → fire → optional extract. Weapon ranges must be checked in DCS | Medium | 1000 |
| A5 | **air assault capture**: Mi-8s land troops in a neutral (or nearly empty) zone | CTLD troops / capture / advance capture | `zone:startPendingCaptureFromAircraft(side, aircraftGroup, ...)` (zC:42901) and `startPendingCaptureWithCargoStatic(side, ...)` (zC:42952) take a side. Helicopter and troop templates exist (`Bandar-force-*` Mi-8, `Bandar-gforce-*`, `CTLD_TROOPS_RED_Squad_8`) | Flight + landing hook + capture call. BLUE's own advance-capture selector is BLUE-only (zC:20316, 45781), so we write the RED one | Medium | 500 |

### B. Fires and electronic warfare

| # | Order | BLUE counterpart | How in Foothold (verified) | To build | Effort | Price |
|---|---|---|---|---|---|---|
| B1 | **fire_mission**: Scud / Iskander / Smerch salvo on a BLUE zone | Cruise missiles | `bc:fireAtZone(zone, launcherGroup, precise, amount)` (zC:22393). It refuses only friendly zones. RED launchers exist: `oscar-scud-1` (Scud event), `Khasab-Forces-attack` (9K720), `qeshm-arty-Attack-Group` / `foxtrot-artillery-fire-at-golf` (Smerch) | List live RED launchers and their range in the snapshot; cooldown per launcher | Low | 800 per salvo (cruisemsl) |
| B2 | **jam**: an EW aircraft blinds a BLUE zone's SAM radars while it lives | `jam` (registered but not sold) | `bc:jamRadarsAtZone(group, zone)` (zC:22057) takes any side. While the jammer group is active, every SAM search and track radar in the zone is set to weapons hold. It has **no distance check** | A RED jammer flight (an orbit near the zone) plus our own range condition (e.g. jam only while within 40 nm), so it is fair and can be shot down. The mission has no RED EW type: use an orbiting Su-24 / Su-34 template, or add an ME template | Low–Medium | 1000 |

### C. Air operations and intelligence

| # | Order | BLUE counterpart | How in Foothold (verified) | To build | Effort | Price |
|---|---|---|---|---|---|---|
| C1 | **exact aircraft choice** for free-form missions, e.g. `RED_SU34_SEAD_KH31Px4...` or a cheap `RED_L39C...` as a decoy ahead of strikers | TALD decoy; choosing CAS/SEAD | A single ME group name works as a capability template (`GroupCommander:_ensureTemplateCache`, zC:55607) | List RED templates by role, era and loadout in the snapshot; price by role | Low | as role |
| C2 | **recon flight → intel**: an An-30M or fighter overflies a BLUE zone; if it survives, RED learns that zone's composition | Zone Spy, intel | `startZoneIntel(zone, duration, side)` (zC:6265) takes a side. Template `AN-30M` exists | Flight to the zone; on arrival, record the BLUE zone's group types for Claude's snapshot (fog of war that matters) | Medium | 150 (intel) |
| C3 | **move AWACS**: put the RED AWACS orbit over a chosen sector | — | `setAwacsRacetrack(side, ...)` / `spawnAwacs(side, ...)` (zC:8944, 9046) take a side; `AWACS_RED` exists | Order plus validation. AWACS detections feed Claude's radar picture through EWRS | Low | free (cooldown) |
| C4 | **hunt player logistics**: strike BLUE FARPs and CTLD-built units once detected | Players hunting RED | Detection first: BLUE FARPs are in `bc.dynamicFarpsBySide[2]` and CTLD units are tracked by BLUE CTLD. Strike: `bc:EngageCasMission(zone, group, ..., side, ...)` (zC:33012) takes a side but targets zones | Report detected BLUE FARPs/CTLD sites to RED only when within RED radar or recon range; add point targeting (CAS on a coordinate) | Medium–High | as role |

### D. Forward base and logistics

| # | Order | BLUE counterpart | How in Foothold (verified) | To build | Effort | Price |
|---|---|---|---|---|---|---|
| D1 | **forward FARP**: Mi-8 flies FARP equipment to a site and builds a RED FARP that RED helicopters launch from | CTLD FARP, farphere | `BuildAFARP` is BLUE-only (country USA, BLUE marks, saved without side). `processMapFarpPurchase` refuses non-BLUE (zC:19174). The registry `bc:registerDynamicFarp(name, coord, side)` (zC:17654) takes a side, but the code that would use a FARP as a launch point is BLUE-only | Our own RED FARP builder (`UTILS.SpawnFARPAndFunctionalStatics` with CJTF Red / Russia), site choice, save/restore, and our own helicopter spawns from it (Foothold capabilities launch from zones only) | High | 1000 (farphere) |
| D2 | **supply airlift**: add supply stock to a RED zone instantly | zsup3 | `zone:_addExpeditedRegularSupplyStock(n)` (zC:47756) works for the zone's side; the BLUE wrapper is BLUE-only (zC:21732) | Direct call plus price. A physical delivery already exists as `supply_run` | Low | 750 (zsup3) |

### Not useful for an AI side
- **Smoke, flare, illumination, JTAC / 9-line:** player aids.
- **Tankers:** AI refuelling isn't modelled.
- **Combined Arms vehicles:** for human ground players.
- **RED warehouse stocking (zwh50 equivalent):** nothing on RED consumes that stock.

## 4. Fog of war that makes these matter
Today RED sees only BLUE aircraft on radar. For C2 and C4 the snapshot would also report, only when detected or recon'd:
- BLUE dynamic FARPs (position, name);
- BLUE CTLD-built SAM sites and vehicles near RED radars;
- BLUE zone composition after a successful RED recon.

## 5. Guardrails
- **No teleporting.** New units appear only inside RED zones or where a RED transport landed. Anything a transport carries can be shot down on the way.
- **Caps:** per zone and in total (deployed groups, ambush teams, active jammers, fire missions per launcher with cooldown). This protects balance and server performance.
- **Credits:** prices from the BLUE shop equivalents, so RED's economy limits what it can do, as it does for players.
- **Visible to players:** RED reinforcements and FARPs are real units that BLUE can find with JTAC, recon or intel. RED jammers and transports are targets.

## 6. Suggested order
1. **Wave 1 (low effort, high value):**
   - A1 deploy_forces
   - A2 exact upgrade
   - B1 fire_mission
   - C1 exact aircraft choice
   - C3 AWACS
   - D2 supply airlift
2. **Wave 2:**
   - A4 heli artillery raid
   - A5 air assault capture
   - A3 ambush teams
   - B2 jammer with range check
3. **Wave 3:**
   - C2 recon → intel
   - C4 hunting BLUE FARPs/CTLD sites
   - D1 RED forward FARPs
