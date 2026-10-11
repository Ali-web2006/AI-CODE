# Iron Throne

A server-authoritative grand-strategy game for Roblox, inspired by Crusader Kings III's *A Game
of Thrones* mod and by Stellaris. You lead a noble house in the Seven Kingdoms of 297 AC: manage
your treasury, develop your lands, court or spurn your neighbours, and outlast rivals governed by
AI rulers who play by the same rules.

**Status:** Phase 1 (foundation and playable prototype) is implemented and verified headlessly;
see [docs/PHASES.md](docs/PHASES.md). The manual Studio playtest in
[docs/TEST_PLAN.md](docs/TEST_PLAN.md) §3 is still to be performed.

## What is in Phase 1

* **Houses:** 10 playable houses (8 great, 2 minor) with real starting positions, rulers, families
  and traits.
* **Map:** 34 provinces with roads, rivers, sea lanes, mountain passes and real chokepoints.
* **Clock:** a server-run campaign clock with pause and three speeds. The host controls it; any
  player who leads a house may pause.
* **Economy:** monthly settlement of income and expenses, from explicit formulas, with a ledger.
* **Develop Province:** a validated action with cost, payback preview and real income effect.
* **Improve Relations:** a validated envoy action. Relations are symmetric and drift back toward
  historical baselines, each with its reason.
* **AI rulers:** they develop their lands and court each other through the same validated
  commands players use.
* **Saves:** versioned save/load with revision-conflict protection, retries, and a labelled
  in-memory fallback when DataStores are unavailable.
* **Interface:** a parchment-and-charcoal UI with a pannable, zoomable political map of the nine
  great houses (flat house colours, crests, castles and ports, hover highlights), five map modes,
  tooltips that explain every number, and a chronicle. It is responsive, with a compact layout
  and touch support.

## Running it in Roblox Studio

1. Install the tools. The versions are pinned in `aftman.toml`; with
   [Aftman](https://github.com/LPGhatguy/aftman), run `aftman install`. You can also install the
   same versions of Rojo, Lune and Selene with any toolchain manager, or with
   `cargo install rojo lune selene`.
2. Install the Rojo Studio plugin (`rojo plugin install`, or from the Creator Store).
3. In this folder run `rojo serve`.
4. In Roblox Studio, create a new Baseplate place, open the Rojo plugin and click **Connect**.
5. Press **Play** (F5). Choose a house in the lobby, then press **Resume** in the top bar.

Alternatively, build a place file and open it: `rojo build default.project.json -o IronThrone.rbxl`.

Studio runs in the *development* environment:
* fixed RNG seed 1337;
* the dev-only "advance to next month" button in the Campaign menu;
* a separate DataStore (`IronThrone_DEV_Campaigns_v1`).

To test real DataStores: publish the place and enable **Game Settings → Security → Enable Studio
Access to API Services**. Without that, saves are kept in server memory and the UI says so.

## Verifying the project

```bash
# once
selene generate-roblox-std                      # Roblox standard library for the linter (roblox.yml)
mkdir -p build
curl -o build/API-Dump.json https://raw.githubusercontent.com/MaximumADHD/Roblox-Client-Tracker/roblox/API-Dump.json
curl -o build/globalTypes.d.luau https://raw.githubusercontent.com/JohnnyMorganz/luau-lsp/main/scripts/globalTypes.None.d.luau
npm --prefix tools/typecheck install            # official Luau analyzer (WASM), for the type check

./scripts/verify.sh
```

`verify.sh` runs:
* a compile check of every file;
* the 81 scenario tests;
* Selene;
* a Rojo build;
* a check of the built place;
* a headless UI smoke test that plays the core loop through the real client and server code;
* a static check of all Roblox API usage against the official API dump;
* a strict-mode Luau type check of every script, using the official analyzer and Roblox type
  definitions.

See [docs/TEST_PLAN.md](docs/TEST_PLAN.md).

## Project layout

```
default.project.json        Rojo mapping (ReplicatedStorage.Shared, ServerScriptService, StarterPlayerScripts)
src/ReplicatedStorage/Shared   config, types, content, pure rules, protocol, text, utilities
src/ServerScriptService        Bootstrap + Simulation (domain) + App (sessions, routing, saves) + Services (Roblox adapters)
src/StarterPlayer/...          ClientBootstrap + Controllers (net, state, map, UI) + UI (theme, components, panels)
tests/                         Lune test runner, harness, specs A–J, place check, UI smoke test, reports
tools/check_roblox_api.py      static Roblox API usage check
tools/typecheck/               strict Luau type check (official analyzer + Roblox definitions)
tools/mapgen/                  map geometry generator (traces a reference map) and the house sigils
tools/render_map_preview.py    PNG preview of the world map from MapData and SigilArt
docs/                          ARCHITECTURE, GAME_DESIGN, PHASES, TEST_PLAN
```

## Documentation

* [Architecture](docs/ARCHITECTURE.md): layers, data flow, state model, network contract,
  security, persistence, extension points.
* [Game design](docs/GAME_DESIGN.md): vision, formulas, content, interface, assumptions.
* [Phases](docs/PHASES.md): what is done, known limitations, the roadmap.
* [Test plan](docs/TEST_PLAN.md): automated coverage and manual Studio procedures.

## Content note

House names, places and characters reference George R. R. Martin's *A Song of Ice and Fire*.
The world map's outlines were traced with `tools/mapgen` from a reference political map supplied
for this project; the image itself is not part of the repository. Map crests are original flat
vector drawings and lobby shields are procedural. No artwork, audio or models from the books or
the television series are included.
