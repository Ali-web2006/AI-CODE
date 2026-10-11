# Phases

A phase is complete only when its systems work end to end, are verified, and are documented.
Having scripts in place is not enough.

## Phase 1 — Foundation and playable strategy prototype

**Status: implemented and verified headlessly. The Studio playtest checklist in TEST_PLAN.md §3 is
still to be run by a human.**

| System | State | Where | Verified by |
|---|---|---|---|
| Rojo project, layered architecture, bootstrap | Done | `default.project.json`, `Bootstrap.server.luau`, `ClientBootstrap.client.luau` | Rojo build, place check |
| Campaign state with stable ids, versioned schema | Done | `CampaignState`, `GameTypes`, `StateInvariants` | Scenario A |
| Data-driven content: 10 houses, 34 provinces, 52 characters, traits, cultures, faiths, bookmark | Done | `Shared/Data` | Scenario A, content validator |
| Startup validation with clear diagnostics | Done | `ContentValidator` | Scenario A (negative cases) |
| Strategic map: provinces, routes, territories, selection, 4 map modes, pan/zoom (mouse and touch) | Done | `MapController` | UI smoke test; Studio §3 |
| House selection with real starting state | Done | `LobbyScreen`, `SessionRegistry` | Scenario B, UI smoke test |
| Top bar: house, ruler, treasury with budget tooltip, holdings, date | Done | `TopBar` | UI smoke test |
| Campaign clock: pause, three speeds, monthly hooks, host policy | Done | `GameClock`, `Simulation`, `CampaignHost` | Scenario D |
| Economy: monthly income and expenses, ledger, formulas in config | Done | `EconomyRules`, `Economy` | Scenarios C, D, E |
| Province inspection and Develop action | Done | `ProvincePanel`, `DevelopProvince` | Scenario E, UI smoke test |
| House relations (symmetric, baselines, drift) | Done | `DiplomacyRules`, `Diplomacy` | Scenario F |
| Improve Relations action | Done | `ImproveRelations` command, `DiplomacyPanel` | Scenario F, UI smoke test |
| AI: scheduled, budgeted, personality-driven; develops and courts through validated commands | Done | `AIDirector` | Scenario G, balance report |
| Server-authoritative requests, rate limits, payload schemas | Done | `CampaignHost`, `PayloadSchema`, `RateLimiter`, `CommandProcessor` | Scenario H |
| Save/load: versioned schema, migrations hook, revision conflicts, retries, in-memory fallback | Done | `CampaignSerializer`, `CampaignRepository`, `PersistenceService` | Scenario I (logic); Studio §3.8 (DataStore) |
| Responsive UI, tooltips, chronicle, notifications | Done | `UIController`, `UI/*` | UI smoke test; Studio §3 |
| End-to-end scenario | Done | full pipeline | Scenario J, UI smoke test |

Known limitations of Phase 1 (by design, deferred to later phases):
* Houses are independent actors. There are no lieges, vassals, titles or claims (Phase 3).
* Characters do not age into events, marry, die or inherit (Phase 2). Ages are displayed and
  computed.
* There are no armies, war or occupation mechanics. The `occupierHouseId` field and its economic
  effect exist for Phase 5.
* Gold accumulates late in long campaigns because there are no armies or buildings to spend it on
  (Phases 5–6).
* Debt has no consequence beyond blocking purchases (Phase 6).
* Persistence is one slot per host. A load replaces the campaign for everyone on the server.
  Persistent shared campaigns and session locking are Phase 7.
* All campaign state is visible to all players (hidden information arrives with intrigue in
  Phase 4).
* The map is a stylised silhouette made of circles. Real map art is Phase 8.

## Phase 2 — Characters, courts and relationships

Depends on: the Phase 1 state model (characters are already state-owned and saved in full).

* Character sheet UI; directional character opinion store with modifiers (separate from house
  relations).
* Births, deaths (health, age), marriages (a command on the relation pair), betrothals.
* Succession rules as data: primogeniture variants, seniority, elective, partition. Ruler death as a
  major event.
* Court positions and appointments.
* Schema migration 1 → 2 (dynasty and birth-house fields).

## Phase 3 — Titles, vassals, claims and feudal government

Depends on: Phase 2 succession.

* Title hierarchy (barony, county, duchy, kingdom, empire) as state entities. Holders, de jure
  links.
* Explicit vassal relationships and obligations (taxes, levies) feeding `EconomyRules`.
* Claims, factions, realm restructuring. The Iron Throne as the top title of the 297 bookmark.

## Phase 4 — Diplomacy, AI and intrigue

Depends on: Phases 2–3.

* Treaties on the relation record: alliances, non-aggression pacts, military access, marriages.
  AI acceptance based on opinion, personality, power and threats.
* Schemes as state entities advanced by a daily system. Secrets, exposure, evidence.
* Event framework: conditions, weights, choices, follow-ups, cooldowns. Text in `Shared/Text`.
* Strategic AI goals, as new candidate generators in `AIDirector`.

## Phase 5 — Warfare and territorial expansion

Depends on: Phase 3 claims, Phase 4 alliances.

* Levies and professional troops, armies and commanders. Movement over the adjacency graph using
  connection kinds and terrain. Supply.
* Battles (composition, commanders, morale, terrain), sieges of holdings, occupation through
  `occupierHouseId`.
* War goals, war score, peace terms, prisoners.

## Phase 6 — Advanced economy and administration

* Buildings and holding upgrades, trade routes, prosperity, food, loans and debt consequences.

## Phase 7 — Persistence, multiplayer campaigns and optimisation

* Campaign-keyed save slots, DataStore session locking, reconnection policies, administrative
  controls.
* Load testing with larger worlds. Replication budgets per player.

## Phase 8 — Content, balance and presentation

* The full known world, more bookmarks and events. Map art, audio, tutorials, accessibility.
