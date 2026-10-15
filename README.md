# Iron Throne

A server-authoritative grand-strategy game for Roblox, inspired by Crusader Kings III's *A Game
of Thrones* mod and by Stellaris. You lead a noble house in the Seven Kingdoms of 297 AC: manage
your treasury, develop your lands, court or spurn your neighbours, and outlast rivals governed by
AI rulers who play by the same rules.

**Status:** the foundation (a playable strategy prototype), Phase 1 (troops and visible
armies) and Part A of the map upgrade (full-height framing, zoom levels and a smooth camera) are
implemented and verified headlessly. The rest of the map upgrade (Parts B–D) is next, then
battles and sieges. See [docs/PHASES.md](docs/PHASES.md). The manual Studio playtest in
[docs/TEST_PLAN.md](docs/TEST_PLAN.md) §3 is still to be performed.

## What is in the game (the foundation and Phase 1)

* **Houses:** 10 playable houses (8 great, 2 minor) with real starting positions, rulers, families
  and traits.
* **Map:** 34 provinces with roads, rivers, sea lanes, mountain passes and real chokepoints.
* **Clock:** a server-run campaign clock with pause and three speeds. The host controls it; any
  player who leads a house may pause.
* **Economy:** monthly settlement of income and expenses, from explicit formulas, with a ledger.
* **Develop Province:** a validated action with cost, payback preview and real income effect.
* **Improve Relations:** a validated envoy action. Relations are symmetric and drift back toward
  historical baselines, each with its reason.
* **Military:** every province musters levies and keeps a garrison, and coasts, islands and ports
  give ships, calibrated to the lore of 297 AC (the Reach fields the largest host, the Iron
  Islands the largest fleet). Twelve unit types with counters, including a unique unit for each
  great house, are kept in one data table. Houses raise armies from their levies (one province or
  all at once, gathering at a rally point), led by their best commanders, and march them over
  roads, rivers, passes and sea lanes, taking days that depend on distance, terrain, connection
  and the pace of their men (swift units such as Dornish spearmen and Reach cavalry quicken a
  host). Armies can be stopped, split, merged and disbanded; they cost upkeep for every day in the
  field, live off their own land and starve abroad. Levies refill monthly. Levy and garrison
  maximums already take modifiers from a buildings hook, which the buildings phase will fill.
* **AI rulers:** they develop their lands and court each other through the same validated
  commands players use.
* **Saves:** versioned save/load with revision-conflict protection, retries, and a labelled
  in-memory fallback when DataStores are unavailable.
* **Interface:** a parchment-and-charcoal UI with the world map below, six map modes, tooltips
  that explain every number, and a chronicle. It is responsive, with a compact layout and touch
  support.
* **The world map:**
  * The whole-map view fits Westeros, from Beyond the Wall to the tip of Dorne, to the full
    height of the map area with a thin margin of sea. Westeros is tall and narrow, so on a wide
    screen the sea shows on both sides; `MapConfig.View.FitMode = "fill"` makes it cover the
    whole map area instead (drag to see the rest). You cannot zoom out past the whole-map view or
    drag off into empty sea; the empty sea east of the Stepstones, where Essos would be, is out
    of reach.
  * Zoom smoothly with the mouse wheel (towards the pointer; near Westeros's edges the view
    slides a little to keep it on screen), a two-finger pinch (which also pans) or the
    + / − / [ ] buttons; choosing a province or an army in a panel flies the map there. The map
    is drawn from vector shapes, not pictures, so borders, names and icons stay sharp at every
    zoom.
  * Zoom levels. From afar it is the political map of the nine great houses: flat house colours,
    crests, castles and ports, hover highlights. Zooming in crosses a blend zone where the house
    colours fade into an atlas of the land and become thin kingdom borders in each house's
    colour (hovering a region then gives it a faint fill in that colour). Closer still is the
    atlas, where settlements will appear with the next parts of the map upgrade.
  * The atlas and the Terrain map mode share one muted palette of the land, one colour per
    province: snow beyond the Wall, the cold grey-green North, the marshes of the Neck, the grey
    Iron Islands, the lush Riverlands, the Vale's green valleys (its mountain provinces greyer),
    the green-brown Westerlands, the rich green Reach (its farmlands golden green), the soft green
    Crownlands, the dark forests of the Stormlands, and Dorne's sand and ochre (its mountain
    provinces tinted the reddish brown of the Red Mountains). The data map modes (Realm,
    Relations, Wealth, Military) keep their own colours at every zoom.
  * Every map setting (framing, zoom levels, camera speeds, colours) is in one file,
    `src/StarterPlayer/StarterPlayerScripts/UI/MapConfig.luau`, which explains each number in
    plain words.
* **Armies in the interface:**
  * Every army is a banner token on the map in its house's colour, with a small crest and its
    troop count. It glides smoothly between provinces as the days pass, and the orders of your
    marching armies are drawn as a dotted route ending in an arrowhead.
  * The province panel shows each province's levies, garrison and ships and the armies standing
    there, and raises its levies or calls every levy of your house to it.
  * The Military tab sums up your troops, lists your armies and shows the selected one: its
    commander, strength, composition by unit, morale, supply and orders, with Move, Stop, Split,
    Merge and Disband.
  * Move by picking a province on the map, or right-click land (or another army's banner) with an
    army selected. Esc, a right-click or leaving the Military tab cancels.
  * The Military map mode shades provinces by the men present and labels every garrison.
  * The top bar shows your house's total troops, with a breakdown in its tooltip.
  * Every disabled button says why.

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
* the 126 scenario tests;
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
tests/                         Lune test runner, harness, specs A–L, place check, UI smoke test, reports
tools/check_roblox_api.py      static Roblox API usage check
tools/typecheck/               strict Luau type check (official analyzer + Roblox definitions)
tools/mapgen/                  map geometry generator (traces a reference map) and the house sigils
tools/render_map_preview.py    PNG preview of the world map from MapData and SigilArt
docs/                          ARCHITECTURE, GAME_DESIGN, PHASES, TEST_PLAN
ASSETS.md                      every map image and data file and how it was made
```

## Documentation

* [Architecture](docs/ARCHITECTURE.md): layers, data flow, state model, network contract,
  security, persistence, extension points.
* [Game design](docs/GAME_DESIGN.md): vision, formulas, content, interface, assumptions.
* [Phases](docs/PHASES.md): what is done, known limitations, the roadmap.
* [Test plan](docs/TEST_PLAN.md): automated coverage and manual Studio procedures.
* [Assets](ASSETS.md): every image and data file of the map and how it was made.

## Content note

House names, places and characters reference George R. R. Martin's *A Song of Ice and Fire*.
The world map's outlines were traced with `tools/mapgen` from a reference political map supplied
for this project; the image itself is not part of the repository. Map crests are original flat
vector drawings, the map's land colours are hand-chosen and lobby shields are procedural; only
Roblox's built-in fonts are used. No artwork, audio or models from the books or the television
series are included. [ASSETS.md](ASSETS.md) lists where every map asset comes from.
