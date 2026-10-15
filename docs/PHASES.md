# Phases

A phase is complete only when its systems work end to end, are verified, and are documented.
Having scripts in place is not enough.

The game is built in two stages. The foundation, a playable strategy prototype, came first. The
armies programme follows it in five phases: troops and visible armies (Phase 1), battles and
sieges (Phase 2), Ironborn raiding with sea zones and fleets (Phase 3), AI personalities and
stances (Phase 4), and resources and buildings (Phase 5). The rest of the long-term plan comes
after it (Phases 6–10). A map upgrade in four parts (A–D) comes between Phase 1 and Phase 2.

## Foundation — playable strategy prototype

**Status: done and verified headlessly. The Studio playtest checklist in TEST_PLAN.md §3 is still
to be run by a human.**

| System | State | Where | Verified by |
|---|---|---|---|
| Rojo project, layered architecture, bootstrap | Done | `default.project.json`, `Bootstrap.server.luau`, `ClientBootstrap.client.luau` | Rojo build, place check |
| Campaign state with stable ids, versioned schema | Done | `CampaignState`, `GameTypes`, `StateInvariants` | Scenario A |
| Data-driven content: 10 houses, 34 provinces, 52 characters, traits, cultures, faiths, bookmark | Done | `Shared/Data` | Scenario A, content validator |
| Startup validation with clear diagnostics | Done | `ContentValidator` | Scenario A (negative cases) |
| World map: political map of the nine great houses traced from a reference, sub-territories, crests, locations, hover, selection, 6 map modes (the sixth, Military, came with Phase 1), pan/zoom (mouse and touch) | Done | `MapData`, `MapController`, `SigilView` | Scenario K, UI smoke test; Studio §3 |
| House selection with real starting state | Done | `LobbyScreen`, `SessionRegistry` | Scenario B, UI smoke test |
| Top bar: house, ruler, treasury with budget tooltip, troops (Phase 1), holdings, date | Done | `TopBar` | UI smoke test |
| Campaign clock: pause, three speeds, daily and monthly hooks, host policy | Done | `GameClock`, `Simulation`, `CampaignHost` | Scenario D |
| Economy: monthly income and expenses, ledger, formulas in config | Done | `EconomyRules`, `Economy` | Scenarios C, D, E |
| Province inspection and Develop action | Done | `ProvincePanel`, `DevelopProvince` | Scenario E, UI smoke test |
| House relations (symmetric, baselines, drift) | Done | `DiplomacyRules`, `Diplomacy` | Scenario F |
| Improve Relations action | Done | `ImproveRelations` command, `DiplomacyPanel` | Scenario F, UI smoke test |
| AI: scheduled, budgeted, personality-driven; develops and courts through validated commands | Done | `AIDirector` | Scenario G, balance report |
| Server-authoritative requests, rate limits, payload schemas | Done | `CampaignHost`, `PayloadSchema`, `RateLimiter`, `CommandProcessor` | Scenario H |
| Save/load: versioned schema, migrations, revision conflicts, retries, in-memory fallback | Done | `CampaignSerializer`, `CampaignRepository`, `PersistenceService` | Scenario I (logic); Studio §3.8 (DataStore) |
| Responsive UI, tooltips, chronicle, notifications | Done | `UIController`, `UI/*` | UI smoke test; Studio §3 |
| End-to-end scenario | Done | full pipeline | Scenario J, UI smoke test |

## Phase 1 — Troops and visible armies

**Status: done and verified headlessly. The Studio checklist in TEST_PLAN.md §3.10–3.11 is still
to be run by a human.**

| System | State | Where | Verified by |
|---|---|---|---|
| Levies, garrisons and ships per province, from development, holding type (a fortress keeps a bigger garrison, a city raises fewer levies but pays more tax), terrain and region, with a buildings hook on both maximums; house totals calibrated to the lore of 297 AC | Done | `MilitaryRules`, `HoldingKindDefinitions`, `TerrainDefinitions`, `RegionDefinitions` | Scenario L |
| One unit table: 12 unit types, class counters (spear > cavalry > archer > spear, siege > walls), a composition per house and a unique unit per great house | Done | `UnitDefinitions`, `ContentValidator` | Scenarios A, L |
| Armies: raise, call all levies, move, stop, split, merge, disband; commanders; movement over the adjacency graph in days by distance, connection, terrain and the pace of the men; sea lanes with ships; supply, morale, starvation and desertion; upkeep for every day in the field | Done | `Military`, `MovementRules`, army commands | Scenarios L, H (fuzzing) |
| Saves: schema 2 (armies, pools, accrued upkeep), migration from schema 1, pools and army morale and supply lowered to the current maximums after a retune | Done | `CampaignSerializer` | Scenario I |
| Army tokens on the map (banner in the house colour with its crest and a large troop count), smooth movement between the server's legs, dotted routes with arrowheads | Done | `ArmyLayer`, `MapController` | UI smoke test; Studio §3.11 |
| Military tab (your forces, the army list, the selected army: commander, troops, composition, morale, supply, orders), military section of the province panel, troops in the top bar, Military map mode | Done | `ArmyPanel`, `ArmyInfo`, `ProvincePanel`, `TopBar`, `MapController` | UI smoke test; Studio §3.10–3.11 |

Known limitations (by design, deferred to later phases):
* Armies exist, but there are no battles, sieges, wars or occupation, and the AI does not raise
  armies. Armies of different houses can stand in the same province. `occupierHouseId` and its
  economic effect exist for Phase 2.
* Unit counters, siege damage and the terrain, region and situation multipliers are data for the
  battles of Phase 2 and the raids of Phase 3; today they only show in tooltips.
* An army cannot detach units by type; Split halves every unit.
* Gold accumulates in long all-AI campaigns because the AI does not raise armies and there are no
  buildings to spend it on (Phases 4 and 5).
* Debt has no consequence beyond blocking purchases (Phase 5).
* Houses are independent actors. There are no lieges, vassals, titles or claims (Phase 7).
* Characters do not age into events, marry, die or inherit (Phase 6). Ages are displayed and
  computed.
* Persistence is one slot per host. A load replaces the campaign for everyone on the server.
  Persistent shared campaigns and session locking are Phase 9.
* All campaign state is visible to all players (hidden information arrives with intrigue in
  Phase 8).
* The map shows the nine great houses only; minor-house fiefs, rivers and roads are not drawn
  (adjacency still exists in the content). MapData supports minor houses through sub-territory
  `houseId` overrides.

## Map upgrade — a framed, zoomable map of Westeros

**Status: Part A done and verified headlessly. The Studio checklist in TEST_PLAN.md §3.13 is still
to be run by a human. Parts B–D come next, each after the go-ahead; Phase 2 follows the map
upgrade.**

| System | State | Where | Verified by |
|---|---|---|---|
| Part A — framing: the whole-map view fits Westeros (`MapConfig.View.Bounds`: Beyond the Wall to the tip of Dorne with a thin sea margin) to the full height of the map area (the old view used 98% of it, so Westeros is about 2% larger); the zoom cannot go out past that view; panning is limited to the frame, so the view never leaves it for empty sea and the empty sea east of the Stepstones, where Essos would be, is out of reach; `FitMode = "fill"` is the one-line switch that makes Westeros cover the whole map area | Done | `MapConfig`, `MapController` | UI smoke test; Studio §3.13 |
| Part A — zoom levels, counted from the whole-map view (`MapConfig.Zoom`): political; a blend zone where the political picture fades over an atlas of the land, crests and house names fade out, and kingdom borders in the house colours (with a faint fill on hover) replace the black borders at `BorderSwitch`; atlas, notable and close thresholds for the settlements to come | Done | `MapConfig`, `MapController` | UI smoke test; Studio §3.13 |
| Part A — the camera: eased flights (province and army focus, + / − / [ ], quick clicks adding up), a smooth wheel zoom towards the pointer that a drag carries along, pinch zoom about the fingers with a two-finger pan, after which the finger still down pans on; it runs on RenderStepped only while moving; the view keeps its middle when the map area changes size | Done | `MapController` | UI smoke test; Studio §3.13 |
| Part A — one muted lore palette for the atlas look and the Terrain map mode, tuned so each region reads as its look by area; `MapConfig` as the one tuning file of the 2D map (it replaces `MapStyle`); `ASSETS.md`, the origin of every map asset | Done | `MapConfig`, `ASSETS.md` | UI smoke test |
| Parts B–D — settlements by zoom level (the major ones in the atlas, all of them with names close in), terrain features, kingdom names, generated atlas terrain tiles, an information panel, map layers and search | Next | | |

Known limitations of Part A (by design):
* The atlas look is a placeholder until the terrain tiles of the later parts: one flat lore
  colour per province, varied slightly per sub-territory, with no relief, rivers or settlements.
* The colour of a province comes from its region and its game terrain type, so a whole province
  has one look (the Greenblood's valley is a greener tint of Dorne's sand). The large mountain
  provinces (the Eyrie, the Bloody Gate, the Golden Tooth, Kingsgrave, Yronwood) only lean toward
  their mountain colour, so that each region still reads as its look; the mountain ranges
  themselves come with the terrain data of Part C.
* Westeros is tall and narrow (about 1 : 2) and the map area wide (816 × 662 on the design
  layout), so the whole-map view fitted to the full height leaves sea at both sides; Part A makes
  it only about 2% larger. `MapConfig.View.FitMode = "fill"` makes Westeros cover the whole map
  area instead: the top and bottom are then off screen until you drag, and the zoom levels,
  counted from the whole-map view, keep that view political.
* Wheel and pinch zoom keep the point under the pointer fixed except near Westeros's edges,
  where the view slides just enough to stay within the panning limits (zooming in at Pyke from
  the whole-map view, Pyke ends about 40 px from the pointer).

## Phase 2 — Battles and sieges

Depends on: Phase 1 armies.

* Battles when hostile armies meet: composition and the class counters, commanders, morale,
  terrain and region multipliers, casualties and retreat.
* Sieges of holdings: garrisons and walls, siege engines against walls, starvation of the
  besieged; occupation through `occupierHouseId`.
* Wars to give them a cause: declarations, war goals, war score and peace terms.
* Schema migration 2 → 3.

## Phase 3 — Ironborn raiding, sea zones and fleets

Depends on: Phase 2 battles.

* Sea zones between the coasts; fleets as entities that move through them, carry armies and
  blockade ports, instead of ships that are only a count.
* Raiding: reavers land, plunder and leave, using the units' raid and landing multipliers. The
  Iron Islands' small host and great fleet become a playable style.

## Phase 4 — AI personalities and stances

Depends on: Phases 2–3.

* AI personalities and stances (aggressive, defensive, opportunistic and the like) towards each
  house, driving war, peace, raiding and the use of armies.
* Military AI as new candidate generators in `AIDirector`, pre-validated with the same
  `Military.check*` functions.
* Human and AI houses are treated the same: the same commands, rules and information.

## Phase 5 — Resources and buildings

Depends on: Phase 1 levies (the buildings hook) and the economy.

* Resources and buildings: holding upgrades, barracks, walls and ports that fill
  `MilitaryRules.poolModifiers` and the budget lines.
* Trade routes, prosperity, food, loans and the consequences of debt.

## Phase 6 — Characters, courts and relationships

Depends on: the foundation's state model (characters are already state-owned and saved in full).

* Character sheet UI; directional character opinion store with modifiers (separate from house
  relations).
* Births, deaths (health, age), marriages (a command on the relation pair), betrothals.
* Succession rules as data: primogeniture variants, seniority, elective, partition. Ruler death as a
  major event.
* Court positions and appointments; dynasty and birth-house fields.

## Phase 7 — Titles, vassals, claims and feudal government

Depends on: Phase 6 succession.

* Title hierarchy (barony, county, duchy, kingdom, empire) as state entities. Holders, de jure
  links.
* Explicit vassal relationships and obligations (taxes, levies) feeding `EconomyRules` and
  `MilitaryRules`.
* Claims, factions, realm restructuring. The Iron Throne as the top title of the 297 bookmark.

## Phase 8 — Diplomacy and intrigue

Depends on: Phases 6–7.

* Treaties on the relation record: alliances, non-aggression pacts, military access, marriages.
  AI acceptance based on opinion, personality, power and threats.
* Schemes as state entities advanced by a daily system. Secrets, exposure, evidence.
* Event framework: conditions, weights, choices, follow-ups, cooldowns. Text in `Shared/Text`.

## Phase 9 — Persistence, multiplayer campaigns and optimisation

* Campaign-keyed save slots, DataStore session locking, reconnection policies, administrative
  controls.
* Load testing with larger worlds. Replication budgets per player.

## Phase 10 — Content, balance and presentation

* The full known world, more bookmarks and events. Map art, audio, tutorials, accessibility.
