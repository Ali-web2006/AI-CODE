# Architecture

Iron Throne is a server-authoritative grand-strategy simulation for Roblox, written in typed
Luau and synchronised into Studio with Rojo. This document describes how the code is organised,
how data flows, and where future systems plug in.

## 1. Layers

```
src/
├── ReplicatedStorage/Shared/        Shared by server and client. No privileged mutation.
│   ├── Config/GameConfig.luau        Every tunable constant (deep-frozen)
│   ├── Types/GameTypes.luau          Typed schema: definitions, campaign state, commands, events
│   ├── Data/                         Immutable content
│   │   ├── World/                    Provinces, terrain, holdings, regions, MapData, SigilArt
│   │   ├── Houses/                   House identities and heraldry
│   │   ├── Characters/               Traits, cultures, faiths
│   │   ├── Bookmarks/                Scenarios: start date, rulers, ownership, relations, characters
│   │   └── Content.luau              Single entry point: indexed, frozen content
│   ├── Rules/                        Pure formulas (economy, diplomacy, traits, character facts)
│   ├── Net/Protocol.luau             Remote names, command names, result codes
│   ├── Text/EventText.luau           Player-facing narrative text for events
│   └── Util/                         CalendarDate, DeterministicRng, Signal, TableUtil
├── ServerScriptService/
│   ├── Bootstrap.server.luau         The only server Script
│   ├── Simulation/                   Pure Luau domain layer. No Roblox services.
│   ├── App/                          Application layer: sessions, request routing, persistence. No Roblox services.
│   └── Services/                     Thin Roblox adapters: Heartbeat, remotes, DataStore
└── StarterPlayer/StarterPlayerScripts/
    ├── ClientBootstrap.client.luau   The only client LocalScript
    ├── Controllers/                  Net transport, replica, state sync, actions, map, UI orchestration
    └── UI/                           Theme, components, tooltip, screens and panels
```

Dependency rules (enforced by structure, checked in review):

* `Shared` never requires server or client code.
* `Simulation` and `App` never call Roblox services (only `game:GetService("ReplicatedStorage")` to
  reach shared modules). They are therefore executable headlessly. The test suite runs them
  under Lune with the real `require(script.Parent.X)` paths.
* `Services` are the only server modules that touch `Players`, `RunService`, `DataStoreService`,
  `HttpService` or remotes.
* The client never mutates game state. It reads the replica and sends commands.
* No circular requires: domain modules receive a `SimContext` (state, config, journal,
  diagnostics, session predicate) instead of requiring `Simulation`.

The suggested service list in the brief (`HouseService`, `ProvinceService`, …) was deliberately
not created as empty modules. Their responsibilities live in focused domain modules (`Economy`,
`Diplomacy`, `CampaignState`, `AIDirector`), and Roblox-specific concerns live in three adapters.

## 2. The authoritative flow

```
Player input (button)
  -> ActionController.run            (client: busy guard, own thread)
  -> NetClient.request               (RemoteFunction "Command")
  -> RemoteService                   (server adapter, passes through untouched)
  -> CampaignHost.handleRequest      type checks, session lookup, token-bucket rate limit,
                                     payload schema, routing
  -> CommandProcessor.submit         command lookup, schema, actor can act,
                                     command.validate (ownership, cost, cooldown, limits),
                                     command.execute in pcall, post-condition invariants
  -> Economy / Diplomacy             domain operation mutates CampaignState exactly once
  -> ChangeJournal                   marks dirty entities and records structured events
  -> CampaignHost.collectReplication per-player, sequenced deltas (RemoteEvent "StateDelta")
  -> StateController / ReplicaStore  merge; gap or resync -> fetch full snapshot
  -> UI panels                       refresh only what changed
```

AI rulers use the same `CommandProcessor.submit` with an `ai` actor, so they cannot skip costs or
validation.

## 3. State model

| Kind | Where | Notes |
|---|---|---|
| Immutable content | `Shared/Data` via `Content` | Identity, geography, heraldry, traits, bookmarks. Deep-frozen. |
| Mutable campaign state | `CampaignState` (server) | Plain tables keyed by stable string ids; no Instances; serializable. |
| Player session state | `SessionRegistry` (server) | Player-to-house control, host, reconnect reservations. Not saved with the campaign. |
| Runtime-only helpers | `Simulation` | Clock accumulator, change journal. Never saved. |
| Presentation state | `UIController` (client) | Selected province, active tab, panel visibility. |
| Persisted data | DataStore slot per host | Versioned save record (§7). |

Entity separation: realm, house, character, province and (in later phases) title are distinct
entities. In Phase 1 a house is the political actor. Characters belong to houses and are fully
owned by campaign state, because they will be born, marry and die. Provinces keep geography in
content and only mutable fields in state.

### Authoritative fields

| Field | Changed only by |
|---|---|
| `clock.date`, `clock.lastProcessedMonthIndex` | `Simulation.advanceDay` / `processMonth` |
| `clock.speed`, `clock.paused` | `Simulation.setSpeed/setPaused` via host policy |
| `houses[id].treasury` | `Economy.processMonth`, `Economy.develop`, `Diplomacy.applyImproveRelations` |
| `houses[id].ledger` | `Economy.processMonth` |
| `provinces[id].ownerHouseId` | bookmark (Phase 5 adds conquest) |
| `provinces[id].occupierHouseId` | reserved for Phase 5 (occupied provinces yield nothing to the owner) |
| `provinces[id].development` | `Economy.develop` |
| `relations[key].score` | `Diplomacy.applyImproveRelations`, monthly drift |
| `rng.state` | every random decision (`DeterministicRng`) |

`StateInvariants.check` verifies all of the above. It runs on every loaded save and in the tests.

### Relations are symmetric

One `RelationState` exists per unordered pair, keyed `"<smaller id>|<larger id>"`. It represents
the standing between two houses as political entities, and treaties will attach to the same
record. Directional, personal feelings belong to the future character-opinion system and are
deliberately not stored here.

## 4. Time and scheduling

* `GameClock` converts real server seconds into whole days. Speeds are 0.40, 0.15 and 0.05 s/day.
  Pause is a separate flag, so resuming restores the previous speed.
* One `RunService.Heartbeat` connection drives the whole campaign. There are no per-entity loops.
* A server hitch can produce at most `MaxDaysPerStep` (10) days. Any backlog beyond that is
  discarded, so there is no catch-up spiral.
* `Simulation.advanceDay` advances the `CalendarDate` (365-day calendar, no leap years), runs
  daily systems (an empty extension point in Phase 1) and, when the month changes, runs the
  monthly systems for the month that ended: Economy, Diplomacy drift, AI.
* The monthly guard: `lastProcessedMonthIndex` increases exactly once per month. Processing a month
  at or before it is refused and logged. Scenario D verifies this under constant speed changes,
  pauses and hitches.

Multiplayer clock policy (`GameConfig.Sessions`):
* The host is the longest-connected player. The role passes on when the host leaves.
* The host sets the speed and resumes the campaign.
* Any player who leads a house may pause.
* When nobody leads a house, the clock pauses automatically.

## 5. Network contract

Remotes are created by `RemoteService` in `ReplicatedStorage.IronThroneNet`:

| Remote | Type | Direction | Payload |
|---|---|---|---|
| `Command` | RemoteFunction | client → server | `(commandName, payload?)` → `{ ok, code, message, data? }` |
| `Sync` | RemoteFunction | client → server | `()` → `{ seq, campaign, session }` or nil if rate limited |
| `StateDelta` | RemoteEvent | server → client | `{ seq, campaign?, events?, session?, resync? }` |

The server never calls `InvokeClient`. Commands (see `Protocol.Commands`) and their payload schemas:

| Command | Payload | Authorisation |
|---|---|---|
| `SelectHouse` | `{ houseId }` | connected, no house yet, house free and not reserved |
| `SetPaused` | `{ paused }` | pause: host or any house leader; resume: host |
| `SetSpeed` | `{ speed }` (1..3) | host |
| `DevelopProvince` | `{ provinceId }` | leads the owning house (house taken from the session) |
| `ImproveRelations` | `{ targetHouseId }` | leads a house |
| `GetSaveInfo` | none | connected; 3 s cooldown |
| `SaveCampaign`, `LoadCampaign` | none | host; 10 s cooldown |
| `DebugAdvanceMonth` | none | host, development environment only |

Deltas carry only the entities marked dirty since the last flush, built per viewer by `Snapshot`.
In Phase 1 all campaign state is public; events are filtered by audience. Each player has their
own sequence number. A gap, or a `resync` marker (sent after a load), makes the client fetch a
full snapshot. Flushes are batched every `ReplicationInterval` (0.1 s) and forced right after each
player request.

## 6. Security

Implemented in `CampaignHost.handleRequest`, `PayloadSchema`, `RateLimiter` and `CommandProcessor`:

* Command name type and length are checked.
* Per-player token bucket: 8 burst, 3/s refill. Storage commands have extra cooldowns.
* Strict payload schemas reject:
  * non-table payloads
  * metatables
  * unknown or non-string keys
  * more than 8 keys
  * ids over 48 characters or outside `[A-Za-z0-9_]`
  * NaN or fractional speeds
* The acting house always comes from the server-side session, never from the payload.
* Ownership, cost, limits and cooldowns are validated at execution time, against current state.
* `execute` runs in `pcall`. Commands compute first and mutate last. Treasuries are checked after
  every command.
* Rejections are logged through `Diagnostics.throttled`, so spam cannot flood the output.

Scenario H covers this, including 2,000 fuzzed requests that must never throw or create gold.

## 7. Persistence

Phase 1 persists one campaign slot per host player (`host_<userId>`):
* In development (Studio), saves go to the DataStore `IronThrone_DEV_Campaigns_v1`.
* In production, they go to `IronThrone_Campaigns_v1`.

Save record (schema version 1, `CampaignSerializer`):

```
{ format = "IronThroneCampaign", schemaVersion = 1, savedAt, revision, writerSessionId,
  summary = { campaignId, bookmarkId, date, hostHouseId },
  campaign = { campaignId, bookmarkId, seed, rngState,
               clock = { date, speed, lastProcessedMonthIndex },
               houses = { [id] = { treasury, rulerId, extinct, ledger, aiNextEvaluationMonth } },
               provinces = { [id] = { ownerHouseId, occupierHouseId?, development } },
               characters = { [id] = { full character record } },
               relations = { [key] = { score, baseline, cooldowns } } } }
```

* **Explicit fields:** every field is written and read explicitly, and type-checked on load.
  `StateInvariants` must pass before a loaded state replaces the live campaign; otherwise the live
  campaign is untouched.
* **Migrations:** `MIGRATIONS[n]` upgrades schema `n` to `n + 1`. A save from a newer schema is
  refused.
* **Content drift:**
  * Entities added to content after a save are initialised from the bookmark, with a warning.
  * Entities that no longer exist make the load fail.
* **Concurrency:** every write uses `UpdateAsync` with an optimistic `revision` check inside the
  transform. A server that last saw revision 3 cannot overwrite revision 4; it gets `SaveConflict`.
* **Transient failures:** bounded retries with 1, 2 and 4 second backoff. A request budget check
  runs before each call. Records over 3.5 MB are refused before writing.
* **Fallback:** if DataStores are unreachable (unpublished place, Studio API access off), a
  clearly labelled in-memory backend is used. It round-trips data through JSON exactly like a
  DataStore, but nothing survives a server restart, and the UI says so.
* **Saving triggers:**
  * a manual save (host)
  * an autosave every 300 s, if anything changed
  * a final save in `BindToClose`

  Nothing writes on UI interaction.
* **Loading:** a loaded campaign always starts paused. The host is restored to the house they led.

## 8. AI

`AIDirector.processMonth` runs inside the monthly systems:

* At most `MaxEvaluationsPerMonth` houses are evaluated. The start offset rotates monthly so no
  house starves, and AI cost scales with this budget, not with world size.
* Houses led by a connected player are skipped.
* Personality = base personality + the ruler's trait `aiWeights`.
* An evaluation rolls `actChance` on the campaign RNG, then builds candidates:
  * developments, scored by payback
  * envoys, scored by proximity and how bad relations are
* Anything the house cannot afford after its cash reserve is discarded. The best candidate is
  submitted through `CommandProcessor`.
* Adding behaviours means adding candidate generators.

Determinism: the same seed reproduces the same campaign (Scenario G compares two 5-year runs
field by field).

## 9. Client architecture

* `NetClient`: transport. Never throws; failures become results.
* `StateController` + `ReplicaStore`: snapshot + sequenced deltas. `ReplicaStore` is pure and
  unit-tested.
* `ActionController`: sends commands with a per-action busy guard, and reports results.
* `UIController`: three ScreenGuis:
  * backdrop
  * main, inside core-UI safe insets
  * overlay, for tooltips

  One `UIScale` fits the 1280×720 design to any screen. Below 1100 virtual pixels of width, a
  compact layout narrows the navigation rail and the panel, which can also be hidden. Each panel
  updates in isolation, so one failing view cannot stop the others.
* `MapController` draws `Data/World/MapData` (outlines, palettes, crests, locations):
  * Fills: Roblox GUI has no polygon fill, so a `ViewportFrame` looks straight down at flat
    triangles (`UI/FlatTriangles`: two WedgeParts per triangle, full ambient light, so colours
    are exact). Outlines are triangulated by `Shared/Util/Polygon` (ear clipping) at startup.
  * Canvas: a map-sized frame moved and resized with the view. Its children are placed in scale
    units, so panning and zooming need no per-element work: borders and highlights (`Path2D`,
    constant on-screen width), crests (`UI/SigilView`), location icons (`UI/MapIcons`) and labels.
    The `ViewportFrame` camera is recomputed from the same zoom and offset.
  * Interaction: hover hit-tests the sub-territories (bounding box, then point in polygon) to
    brighten one, outline its region and feed the tooltip; a click selects the sub-territory's
    province through `onSelect`, exactly as the old province markers did.
  * Drawing rules (border weights, zoom thresholds, crest and label sizes) live in
    `UI/MapStyle`; `tools/render_map_preview.py` mirrors them.
  * Five map modes: houses, realm, relations, wealth, terrain.
* `tools/mapgen/generate_map.py` regenerates the outline block of `MapData` from the reference
  map; `tools/mapgen/build_sigils.py` regenerates `SigilArt` from `tools/mapgen/sigils/*.py`.

## 10. Diagnostics

`Diagnostics` prints `[IronThrone][Subsystem] message`:
* Content errors stop the server at startup, with one line per problem.
* Command rejections are throttled per key.
* System failures inside a month are logged but do not stall the clock.
* Monthly ledgers and AI decisions can be logged through `GameConfig.Debug`.

## 11. Future expansion contract

Each long-term feature, and where it attaches without replacing the foundation:

| Feature | Extension point |
|---|---|
| More houses, provinces, bookmarks, maps | Data files only; `ContentValidator` checks them; saves initialise added content from the bookmark |
| Characters, births, deaths, marriages, inheritance | `CampaignState.characters` is already state-owned and saved in full; add daily/monthly systems and commands; succession rules as data |
| Titles, vassals, claims, governments | New `titles` collection in state + `TitleDefinitions`; houses keep identity; schema migration 1→2 |
| Treaties (alliances, NAPs, marriages, war) | Attach to the symmetric `RelationState` record per pair; commands follow the `check*`/`apply*` pattern |
| Character opinions, traits, secrets, schemes | Directional opinion store separate from house relations; schemes as state entities advanced by a daily system |
| Armies, war, sieges, peace | `occupierHouseId` already separates occupation from ownership; adjacency carries connection kinds for movement; daily systems for movement and sieges |
| Buildings, trade, deeper economy | `EconomyRules.computeHouseBudget` takes per-province lines; add modifiers there |
| Smarter AI | Add candidate generators to `AIDirector`; evaluation budget already bounded |
| Hidden information | `Snapshot` builds every view per viewer; filter there |
| Persistent shared campaigns | Repository and serializer are campaign-shaped; add campaign-keyed slots and session locks (Phase 7) |
