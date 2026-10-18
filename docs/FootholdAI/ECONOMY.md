# Credits: how RED (and BLUE) pay for what Claude orders

Goal: RED has an economy like BLUE's player team. It earns credits by holding ground and by fighting, and Claude decides how to spend them. Nothing extra is free, so a Scud costs as much as a BLUE cruise-missile strike, and a lost helicopter loses its credits.

All numbers are settings (`FootholdAI_Config.lua` → `command = { economy = ..., prices = ..., ops = ... }`) and are meant to be tuned after play-testing.

## 1. How BLUE earns today (Foothold, unchanged)

| Source | Where in Foothold | Amount (PG defaults) |
|---|---|---|
| Zone income | `ZoneCommander:update` → `addFunds(side, income)` every `updateFrequency` (10 s) | `income` per zone. In the Persian Gulf setup only a few zones have income (Factory, Oil Fields, Lar 2 each; mission zones 0.3–0.5) |
| Player kills | `RewardContribution` (Config.lua): infantry 10, ground 10, SAM 30, aircraft 50, helicopter 50, ship 200, structure 100 | Paid into the coalition account when the player **lands**. If the player ejects, 25 % is paid and 75 % is lost |
| Captures and supply | `Zone capture` 200, `Zone upgrade` 100, crate 100, warehouse delivery 150 | Per delivery |
| Missions | CAS/SEAD/strike mission rewards, train kills (1000) | Per mission |

Foothold already gives RED a little: zone income, +100 per RED supply delivery, and +100 when a RED fighter returns home.

## 2. What RED gets now

| Source | How | Setting |
|---|---|---|
| Zone income | Foothold, unchanged | — |
| **Kill rewards** | Any RED AI kill (not a RED player's, which Foothold already pays) earns the same `RewardContribution` amount a BLUE player gets. Ground and ship kills are paid at once. **Aircraft kills are paid when the aircraft lands**; if it is lost first, only `lostAircraftKeeps` (25 %, like an ejecting player) is paid | `economy.killRewards = { red = true, blue = false }`, `rewardScale`, `airKillsPaidOnLanding`, `lostAircraftKeeps` |
| **Capture reward** | `Zone capture` (200) when a zone turns RED | `economy.captureReward` |
| Flat bonus | Optional extra income per minute, if RED is too poor on a map with little zone income | `economy.bonusIncomePerMin = { red = 0 }` |
| Foothold's RED bonuses | Supply deliveries and returning fighters, unchanged | — |

BLUE AI kills earn nothing, as before, because BLUE's credits are the players'. Set `killRewards.blue = true` to change that.

## 3. What costs credits

Prices come from the BLUE shop item that matches each order (`ShopPrices` in Foothold Config.lua), times `priceScale`. So the same thing costs both sides the same.

| Order | Price key | PG price |
|---|---|---|
| Free-form missions (CAP/sweep, CAS, SEAD, runway strike, convoy, artillery) | `dynamiccap` / `dynamiccas` / `dynamicsead` / `dynamicbomb` / `groundattack` | 500–1000 |
| RED purchases (upgrade, depot, repair, mass attack, bomber) | Foothold's RED shop items | as configured by Foothold |
| `deploy_forces` / `upgrade_zone` by category | infantry/ground `zinf`, armor `zarm`, AAA `zvulcan`, SHORAD `zavenger`, SAM `zhawk`, long-range SAM (SA-10 etc.) `zpat`, artillery `zhimars` | 500–5000 |
| `fire_mission` Scud / Iskander | `cruisemsl` | 800 per fire mission |
| `fire_mission` Smerch | `zhimars` | 2500 |
| `heli_raid` | `groundattack` | 1000 |
| `air_assault` | `capture` | 500 |
| `ambush` | `zvulcan` | 500 |
| `jam` | `jam` | 500 |
| `supply_airlift` (3 units) | `zsup3` | 750 |
| `move_awacs` | 0 (10 min cooldown) | 0 |
| Foothold's pre-built capabilities | `economy.capabilityFee` × the role's price | **0 by default** |

**Pre-built capabilities stay free by default.** That is how Foothold works for both sides: the map's own AI flights cost aircraft and warehouse stock, not credits, and BLUE's AI support is free in the same way. Credits buy the extras, as they do for players. If RED launches too much, set `capabilityFee = { red = 0.25 }` (a quarter of the shop price per sortie).

Besides credits, the expensive orders have limits:
- each fire system reloads (Scud and Iskander 30 min, Smerch 20 min);
- at most 2 deployed groups per zone and 12 in total;
- one upgrade slot per zone, as in Foothold;
- 4 ambush teams at once;
- one jammer at a time;
- 6 helicopter and jammer operations at once.

## 4. What Claude sees and does

The snapshot's `economy` block (in `get_overview`) shows:
- credits and the credits cap;
- income per minute;
- spent on orders and earned from combat since the last cycle;
- unpaid air kills (paid if those aircraft land);
- a ledger of the last 25 entries: what was bought and what was earned.

Every order tool checks the price against the credits left this cycle and refuses with "not enough credits" otherwise; the mission checks again when it executes. The RED prompt tells Claude to budget like a player team: keep a reserve, and spend where it moves the front or makes BLUE pay.

## 5. Jamming, fair for both sides
Foothold's `jamRadarsAtZone` (BLUE's shop jammer) silenced every SAM radar of a zone, however far away the jammer was. It is now replaced for **both** sides:
- only SAM search and track radars within `jamming.rangeNm` (40 nm) of a live jammer unit are set to weapons hold;
- a radar that falls out of range, or whose jammer dies, is restored at once;
- the jammer is sent to orbit `standoffNm` (25 nm) from the zone, on its own side, so it can be found and shot down. This includes BLUE's `ewAircraft`, which used to fly its fixed Mission Editor route;
- player-bought SAMs (zone upgrades from the shop) are zone defenders, so they are jammed under the same rule as anything else.

### Adding a dedicated RED jammer (optional)
Out of the box the RED jammer is a copy of the mission's `AN-30M` template (a slow transport, an easy target). To use a proper aircraft:
1. Open the mission (`Foothold_PG_5.3.5_...miz`) in the Mission Editor.
2. Add a RED aircraft group with **one** unit, country CJTF Red or Russia. Any type works (the jamming is scripted); Su-24MR, Su-24M or An-26B suit the role. Give it a sensible loadout (self-defence missiles or none).
3. Name the **group** exactly `ewAircraftRed` and tick **Late activation**. Where you place it, and its route, do not matter: the script spawns a copy at the RED airfield closest to the target and gives it its own route.
4. Save, then patch the saved mission again with `patch_miz.py`.

The dcs.log line `[FootholdAI][ops] RED operations ready (jammer: ewAircraftRed)` confirms it was found. To use a group with another name, set `command = { ops = { jamming = { templates = { red = { 'MyJammer' } } } } }`.
