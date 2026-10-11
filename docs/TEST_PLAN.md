# Test Plan

Testing has two layers:
1. **Automated checks** that run headlessly with Lune, Rojo, Selene and Python. These were all run
   during development and pass.
2. **Manual Studio procedures** for what only the live engine can show: real rendering, input
   devices, DataStores and multiple clients. These have NOT been run yet and must be performed by
   a person with Roblox Studio.

## 1. Running the automated checks

```bash
# one-time setup (see README.md for tool installation)
selene generate-roblox-std        # creates roblox.yml for linting
mkdir -p build
curl -o build/API-Dump.json https://raw.githubusercontent.com/MaximumADHD/Roblox-Client-Tracker/roblox/API-Dump.json
curl -o build/globalTypes.d.luau https://raw.githubusercontent.com/JohnnyMorganz/luau-lsp/main/scripts/globalTypes.None.d.luau
npm --prefix tools/typecheck install

./scripts/verify.sh               # runs everything below
```

| Check | Command | What it proves |
|---|---|---|
| Compile | `lune run tests/compile_check.luau` | Every `.luau` file parses and compiles |
| Scenario tests | `lune run tests/run.luau [filter]` | 81 deterministic tests of the simulation, sessions, security, persistence, the client replica and the world map configuration (Scenarios A–K below) |
| Lint | `selene src tests` | Roblox standard library: globals, Enum items, datatype constructors, unused code |
| Rojo build | `rojo build default.project.json -o build/IronThrone.rbxl` | The project maps into a valid place |
| Place check | `lune run tests/place_check.luau build/IronThrone.rbxl` | The built place has the expected tree; `Players.CharacterAutoLoads` is false; all 75 ModuleScripts (client UI included) resolve their requires and run their top-level code against real Roblox datatypes |
| UI smoke test | `lune run tests/ui_smoke.luau build/IronThrone.rbxl` | The real client code runs against the real server pipeline. Every property assignment is validated against Roblox's reflection database, buttons are clicked by their text, and the whole core loop is played (§2.J) |
| API check | `python3 tools/check_roblox_api.py --dump build/API-Dump.json src` | Class names, property keys in `UI.create`, Enum items, services, events and methods exist in the Roblox API dump |
| Type check | `lune run tools/typecheck/record_requires.luau build/IronThrone.rbxl build/requires.json` then `node tools/typecheck/typecheck.mjs build/requires.json build/globalTypes.d.luau` | Every script type-checks in `--!strict` with the official Luau analyzer (new solver) against luau-lsp's Roblox definitions. Instance-path requires are resolved from recorded call sites, so cross-module types are checked |
| Balance report | `lune run tests/balance_report.luau 30` | Diagnostic only: 30-year all-AI economy table |
| House report | `lune run tests/house_report.luau` | Diagnostic only: starting position of every house |
| Map preview | `lune run tests/map_dump.luau > build/map.json` then `python3 tools/render_map_preview.py build/map.json build/map_preview.png [--zoom 0.5] [--crop x0,y0,x1,y1]` | Diagnostic only: renders the world map from MapData and SigilArt with the game's drawing rules (fills, borders, crests, labels, icons by zoom), so map edits can be reviewed without Studio |
| Map generation | `python3 tools/mapgen/generate_map.py <reference.webp>` and `python3 tools/mapgen/build_sigils.py --sheet build/sigils.png` | Tooling, not a check: regenerates the outline block of MapData from the reference map, and SigilArt from `tools/mapgen/sigils/*.py` (needs numpy, scipy, scikit-image, shapely >= 2.1, Pillow) |

Type-check caveat: Studio's Script Analysis uses its own knowledge of the DataModel. The offline
check emulates the parts that matter (service and `Instance.new` result types, `Enum` type names,
`script` paths), but Studio may still word or classify a warning differently, especially if a
place opts into the older type solver.

Test infrastructure:
* `tests/harness/VirtualRoblox.luau` mirrors the Rojo tree, so modules run with their real
  `require(script.Parent.X)` paths.
* `tests/harness/Fixtures.luau` builds deterministic sims and hosts with synthetic time and JSON
  round-tripping storage.

## 2. Scenario coverage (automated)

| Scenario | Spec | Cases |
|---|---|---|
| A — Initialization | `a_initialization.spec.luau` | All modules load; content validates with no errors or warnings; 10 houses and 34 provinces; invariants hold; starting values come from the bookmark. Validator catches duplicate ids, broken or asymmetric adjacency, bad owners, dead or missing rulers, broken family links. The host refuses to start on bad content. |
| B — House selection | `b_house_selection.spec.luau` | Correct starting state. No second house. No taking another player's house. Unknown houses and unconnected users rejected. Acting house comes from the session (forged `houseId` rejected). Reservation on disconnect and restore on rejoin. Host election. Auto-pause. |
| C — Province inspection | `c_province_inspection.spec.luau` | Five provinces' owners, development and income match the formula; development cost and next-level income; every province in the sync payload; budget equals the sum of its lines. |
| D — Clock | `d_clock.spec.luau` | Paused time frozen; each speed advances ~50 days in 50 day-lengths at 60 Hz; exact multiples exact; negative/NaN/infinite/zero time ignored; hitch capped at 10 days; one simulated year with constant speed changes and pauses processes exactly 12 months; treasury follows the ledger exactly; duplicate month refused; calendar arithmetic; speed and pause permissions. |
| E — Development | `e_development.spec.luau` | Exact cost charged once; development +1; next month's income rises by the formula's amount; unaffordable, foreign, occupied, maxed, unknown and malformed requests all rejected with state unchanged; costs escalate; treasury never negative. |
| F — Diplomacy | `f_diplomacy.spec.luau` | Explained gain (+12 for Stark → Lannister) charged once; preview lines sum to the gain; repeats hit the cooldown without charging; cooldown expires after 6 months; drift of 1 per month; self, unknown, extinct and malformed targets rejected; insufficient funds; clamp at 100. |
| G — AI | `g_ai.spec.luau` | 20 years: no treasury ever negative, invariants hold, development increases, no rejected AI commands. AI both develops and sends envoys. Candidates within spendable gold. Player houses untouched. Same seed gives an identical campaign. Trait-driven personality. Evaluation budget respected. |
| H — Security | `h_security.spec.luau` | Malformed command names; 19 malformed payload shapes; missing house and entities; spam rate limited with the cost charged once; storage cooldowns; save-info throttling; non-host restrictions; debug disabled in production; 2,000 fuzzed requests never throw and create no gold. |
| I — Persistence | `i_persistence.spec.luau` | Fresh and 30-month campaigns round-trip through JSON exactly; 9 malformed saves rejected with reasons; content drift handled; transient failures retried with 1 s and 2 s backoff, and the attempt cap leaves storage untouched; an older session cannot overwrite a newer save; oversized saves refused; host save → play → load restores state and resyncs clients; a corrupt slot leaves the live campaign untouched; unavailable storage reported while gameplay continues; dev and prod storage names differ. |
| J — Integration | `j_integration.spec.luau` + `tests/ui_smoke.luau` | Full session through the request and replication pipeline with the client replica (select → inspect → time → develop → envoy → pause/resume → save → play → load), plus sequence-gap and resync handling. The UI smoke test repeats the loop by clicking the real interface, including the map: drawn land, nine crests and house labels, a click on Harrenhal's land, the hover outline of the Vale, and the sub-territory border toggle. |
| K — World map | `k_map.spec.luau` | Exactly nine great houses with the specified palettes and seats; every region references a valid house and matches a game region; 4–10 sub-territories per region, each selecting a real province of that region, with valid shades; no overlaps and region outlines that agree with their sub-territories (sampled every 9 units); required locations present, each holding on its own province's land and matching the province position; the Wall band at y 80–130 across the continent, the Gift below it, the Stepstones; sigil art for all nine houses; exact triangulation of every outline. |

## 3. Manual Studio procedures (not yet performed)

Setup:
1. Install Rojo and its Studio plugin.
2. `rojo serve`. In Studio, open a new Baseplate place and connect through the Rojo plugin.
3. Play Solo (F5). Watch the Output window: it should show
   `[IronThrone][Campaign] started 'The Long Summer' ...` and
   `[IronThrone][Bootstrap] server ready (development, storage: ...)`.

### 3.1 Start and house selection (Scenarios A, B)
1. **Expected:** the lobby shows the title, the bookmark line and 10 house cards (8 great, then 2
   minor), each with a shield, ruler, provinces, treasury, net income and "Available".
2. Click House Stark. **Expected:** the right side shows the description, ruler and stats, plus a
   "Lead House Stark" button.
3. Click it. **Expected:** the game screen appears, centred on Winterfell; the top bar shows House
   Stark, "Eddard Stark, 33", 140.0 gold, +17.9 per month, and "1 January 297 AC PAUSED".

### 3.2 Map and inspection (Scenarios C, K)
1. Fit the map ([ ]). **Expected:** it matches `build/map_preview.png` from the map preview tool:
   flat house colours with no shading, the black Wall band and Gift, grey Beyond the Wall, nine
   crests and "HOUSE / NAME" labels, the ocean #3D4A63, no gaps between regions.
2. Drag to pan, scroll to zoom, and use the + / − / [ ] buttons. **Expected:** smooth movement at
   60 frames per second (check with Shift+F5 or the MicroProfiler); borders and labels stay sharp;
   castle icons appear from a medium zoom and their names closer in; crests fade when zoomed far in;
   the view cannot be zoomed or panned past its limits.
3. Hover over land. **Expected:** the sub-territory brightens, the whole region gets a light outline,
   and the tooltip names the region, its great house and the province's owner, development and
   income. Moving to the sea clears it.
4. Click the land of King's Landing, The Arbor and Moat Cailin (or their icons). **Expected:** the
   panel shows the matching name, owner, terrain, development and income (20.8, 5.8 and 0.7 gold
   per month), and the province gets a thick gold outline. Clicking the sea clears the selection.
5. Switch between the Houses, Realm, Relations, Wealth and Terrain map modes and toggle
   "Sub-territory borders". **Expected:** the colours, legend and thin borders change.
6. Watch the Output window. **Expected:** no errors or warnings from the map.
4. Hover over a province and over the treasury. **Expected:** tooltips with breakdowns.

### 3.3 Clock (Scenario D)
1. Click Resume, then each speed button. **Expected:** the date advances; months roll over about
   every 12 s, 4.5 s and 1.5 s; the treasury flashes each month; Realm → Settled months gains one
   line per month.
2. Pause. **Expected:** the date stops.

### 3.4 Development (Scenario E)
1. On Winterfell, click "Develop (44 gold)". **Expected:** the treasury drops by 44, development
   shows 5 / 10, the button shows the next cost (57), and a Chronicle entry is added.
2. Spend until short of gold. **Expected:** the button is disabled, and its tooltip states the
   cost and the treasury.

### 3.5 Diplomacy (Scenario F)
1. Open the Diplomacy tab and choose House Lannister. **Expected:** −10 Cold, the baseline reason,
   and a preview of "−10 → 2".
2. Click "Send envoy (25 gold)". **Expected:** relations show 2, the treasury drops by 25, and the
   button is disabled with "Next envoy in 6 months".

### 3.6 AI (Scenario G)
1. Run speed 3 for about two minutes. **Expected:** the Chronicle shows other houses developing
   provinces and courting each other, and the badges on AI provinces increase.

### 3.7 Security (Scenario H)
1. In the client command bar, run:
   `game.ReplicatedStorage.IronThroneNet.Command:InvokeServer("DevelopProvince", { provinceId = "casterly_rock" })`.
   **Expected:** `{ ok = false, code = "NotOwner" }`.
2. Run the same call with `{ provinceId = "winterfell", houseId = "lannister" }`. **Expected:**
   `InvalidPayload`.

### 3.8 Persistence (Scenario I)
1. With no setup, open the Campaign menu. **Expected:** the storage status reads "server memory
   only", or "DataStore" if API access is enabled.
2. Save, advance a few months, then Load last save. **Expected:** the date and treasury are
   restored, and the clock is paused.
3. To test real DataStores:
   * Publish the place.
   * Game Settings → Security → enable "Enable Studio Access to API Services".
   * Restart. **Expected:** the storage status reads "DataStore".
   * Save, stop the session, start a new one. **Expected:** the lobby shows "Last save: …";
     "Load saved campaign" restores it.

   Development builds use the DataStore `IronThrone_DEV_Campaigns_v1` and never touch production
   data.

### 3.9 Multiplayer (Scenarios B, H)
1. In the Test tab, start a Local Server with 2 players. **Expected:** player 1 is host.
2. Player 1 leads Stark; player 2 sees Stark as "Led by Player1" and leads Lannister.
3. Player 2's speed buttons are disabled; player 2 can pause but not resume.
4. Close player 1. **Expected:** player 2 becomes host; Stark is reserved for 5 minutes and
   governed by the AI.

### 3.10 Mobile layout
1. Use the Device emulator (for example an iPhone landscape profile). **Expected:**
   * the compact layout is used;
   * the panel can be hidden;
   * drag and pinch move the map;
   * a long press on a province shows its tooltip.

Record the results of §3 in this file when performed (date, Studio version, pass/fail notes).
