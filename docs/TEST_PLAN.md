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
| Scenario tests | `lune run tests/run.luau [filter]` | 126 deterministic tests of the simulation, sessions, security, persistence, the client replica, the world map configuration and the military (Scenarios A–L below) |
| Lint | `selene src tests` | Roblox standard library: globals, Enum items, datatype constructors, unused code |
| Rojo build | `rojo build default.project.json -o build/IronThrone.rbxl` | The project maps into a valid place |
| Place check | `lune run tests/place_check.luau build/IronThrone.rbxl` | The built place has the expected tree; `Players.CharacterAutoLoads` is false; all 89 ModuleScripts (client UI included) resolve their requires and run their top-level code against real Roblox datatypes |
| UI smoke test | `lune run tests/ui_smoke.luau build/IronThrone.rbxl` | The real client code runs against the real server pipeline. Every property assignment is validated against Roblox's reflection database, buttons are clicked by their text, and the whole core loop is played, armies included (§2.J) |
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
| A — Initialization | `a_initialization.spec.luau` | All modules load; content validates with no errors or warnings; 10 houses and 34 provinces; invariants hold; starting values come from the bookmark. Validator catches duplicate ids, broken or asymmetric adjacency, bad owners, dead or missing rulers, broken family links, invalid unit tables (unknown or foreign units in a composition, shares not summing to 1, bad counters, classes, terrain or situation keys) and invalid military fields of terrains, holdings and regions. The host refuses to start on bad content. |
| B — House selection | `b_house_selection.spec.luau` | Correct starting state. No second house. No taking another player's house. Unknown houses and unconnected users rejected. Acting house comes from the session (forged `houseId` rejected). Reservation on disconnect and restore on rejoin. Host election. Auto-pause. |
| C — Province inspection | `c_province_inspection.spec.luau` | Five provinces' owners, development and income match the formula; development cost and next-level income; every province in the sync payload; budget equals the sum of its lines. |
| D — Clock | `d_clock.spec.luau` | Paused time frozen; each speed advances ~50 days in 50 day-lengths at 60 Hz; exact multiples exact; negative/NaN/infinite/zero time ignored; hitch capped at 10 days; one simulated year with constant speed changes and pauses processes exactly 12 months; treasury follows the ledger exactly; duplicate month refused; calendar arithmetic; speed and pause permissions. |
| E — Development | `e_development.spec.luau` | Exact cost charged once; development +1; next month's income rises by the formula's amount; unaffordable, foreign, occupied, maxed, unknown and malformed requests all rejected with state unchanged; costs escalate; treasury never negative. |
| F — Diplomacy | `f_diplomacy.spec.luau` | Explained gain (+12 for Stark → Lannister) charged once; preview lines sum to the gain; repeats hit the cooldown without charging; cooldown expires after 6 months; drift of 1 per month; self, unknown, extinct and malformed targets rejected; insufficient funds; clamp at 100. |
| G — AI | `g_ai.spec.luau` | 20 years: no treasury ever negative, invariants hold, development increases, no rejected AI commands. AI both develops and sends envoys. Candidates within spendable gold. Player houses untouched (no developments, envoys or armies). Same seed gives an identical campaign. Trait-driven personality. Evaluation budget respected. |
| H — Security | `h_security.spec.luau` | Malformed command names; 33 malformed payload shapes (14 of them for army commands: forged `houseId`, missing or extra fields, non-id, NaN, table and over-long ids); missing house and entities; spam rate limited with the cost charged once; storage cooldowns; save-info throttling; non-host restrictions; debug disabled in production; 2,000 fuzzed requests (army fields included, against a real army) never throw, never fail on the server and create no gold; 1,500 fuzzed army orders against real and foreign armies over five months of play keep every invariant, carry out every kind of order, raise no server error and leave every gold change in the ledger. |
| I — Persistence | `i_persistence.spec.luau` | Fresh, 30-month and mid-march campaigns (armies marching by land and sea, waiting for ships, gathering, leaderless) round-trip through JSON exactly; a schema 1 save loads without warnings, with no armies and full levy and garrison pools sized to the saved development; 9 malformed saves and 26 malformed army, pool and house cases rejected with reasons; a save made before a retune that lowered `LevyPerDevelopment`, `MoraleMax` and `SupplyMax` loads with its pools, morale and supply lowered to the new maximums (with warnings) and plays on; content drift handled; transient failures retried with 1 s and 2 s backoff, and the attempt cap leaves storage untouched; an older session cannot overwrite a newer save; oversized saves refused; host save → play → load restores state and resyncs clients; a corrupt slot leaves the live campaign untouched; unavailable storage reported while gameplay continues; dev and prod storage names differ. |
| J — Integration | `j_integration.spec.luau` + `tests/ui_smoke.luau` | Full session through the request and replication pipeline with the client replica (select → inspect → time → develop → envoy → pause/resume → save → play → load), plus sequence-gap and resync handling. The UI smoke test repeats the loop by clicking the real interface, including the map: drawn land, nine crests and house labels, a click on Harrenhal's land, the hover outline of the Vale, and the sub-territory border toggle. Armies: "Raise levies here (10,800 men)" on Winterfell raises `army_1` (empty pool, the button disabled, the army listed in the province); its token `Army_army_1` shows the count above Winterfell; clicking it opens the Military tab with Eddard Stark as commander (and his martial) and a gold edge on the token; Move… starts move mode, and Esc, the Roblox menu opening and a right-click each cancel it without an order; a supply tick that raises the idle army's morale moves the morale meter without rebuilding the Military tab (the Move… button is the same instance), and another one leaves Winterfell's province panel alone (the same Develop button); switching to the Map tab or hiding the panel cancels move mode, so the next click on land selects the province and sends no order; Move… and a click on Moat Cailin's land send MoveArmy without selecting the province, and the tab shows "Marching to Moat Cailin — arrives in 27 days", a toast confirms the 27 days and a dotted route with an arrowhead is drawn; zooming in twice redraws the route in the same holder with more dots, and zooming back out hides the extra dots without creating or destroying a frame; ten days into the march the dots behind the army are hidden and the estimate reads 17 days; after the time run the army stands at Moat Cailin, its route is gone and, paused, the token sits on Moat Cailin; the Military map mode (button `Mode_military`, labelled "Military") shows its legend and "Garrison …" under the holdings (hidden again in Houses mode); the top bar shows the troop total and "Troops · 1 army", and clicking it opens the Military tab; Split creates `army_2` with a second, stacked token; "Merge with Army of Winterfell (…)" joins them and removes the token; a right-click on Winterfell's land marches the army there (two legs) and Stop shortens the route to the current leg; Disband… then "Confirm disband" removes the token and route and refills the levy pools; a left click on the map selects the province and deselects the army, after which a right-click gives no order; dragging the map by a token pans it without selecting the army, while a click on it does; a right-click on the selected army's own token gives no order whatever land lies under it, and a right-click on another army's token (with the pointer over White Harbor's land) marches the selected army to that army's province, Moat Cailin; an army marching when the campaign is saved has its token (and no other) back after the load; a full snapshot in which `army_3` belongs to House Lannister rebuilds its token in Lannister's colour and clears the selection and the pending move order (the next click on land sends nothing); and after a stay in the lobby during which every army disappeared, the session change on re-entry removes the leftover token. |
| L — Military | `l_military.spec.luau` | Formulas: exact levies, garrisons and ships, growing pools at every development, lore totals and ordering (Tyrell largest; the Vale's host at least 1.3 times Dorne's; Greyjoy the smallest great host but about 200 ships, the most), fortress and city trade-offs; composition split by largest remainder (exact totals, id tie-break), halving, army speed (the head-count-weighted harmonic mean: every great host faster than plain spearmen, Dorne and the Reach fastest, the Stormlands slowest), exact leg days by road, marsh, pass, river and sea, optimal and deterministic routes (checked against Floyd–Warshall for every pair), upkeep, strength and morale. Simulation: raising (composition, emptied pool, best commander, children excluded, journal marks, events); commander ranking; calling every levy (rally first, gathering and merging on arrival into an idle army only, every unit conserved; a new order or a stop releases a gathering army); march timing to the day (Winterfell → Moat Cailin in 27 days, no replication mid-leg); re-routing keeps the current leg; stop; sea crossings (Greyjoy sails Pyke → Lannisport in 9 days, Stark and Frey cannot cross without ships, a small detachment can); ships at sea delay a second embarkation, and a waiting army ordered to the port it waits in is refused ("already at Harlaw"); split and merge conserve every man (weighted morale and supply, commander rules); disband refills pools by shortfall, never above the maximum, without gold; upkeep in the budget and once in the ledger, paid pro rata for the days in the field (disbanded after 15 days: 15/31 of a month; raised on 22 January: 10/31; all month: 18.06); supply drain, starvation attrition and recovery at home, a supply-only tick marking the army but not its house, lost men marking both; desertion; the buildings hook (`MilitaryRules.poolModifiers`, identity today; replaced in the test, it reaches the province and house views, refills, disbanding and the invariants); monthly refills (occupied provinces excepted, rounding free of floating-point noise); every rejection by code with state unchanged; event text; determinism; replication through the host into the client replica, including removals. |
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
5. Switch between the Houses, Realm, Relations, Wealth, Terrain and Military map modes and toggle
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
3. Run `...Command:InvokeServer("RaiseArmy", { provinceId = "casterly_rock" })`. **Expected:**
   `NotOwner`. Then, as another player's house raises an army, try `MoveArmy` or `DisbandArmy` on
   its id from your client. **Expected:** `NotOwner`.

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

### 3.10 Armies from the command bar (Scenario L, server side)
The army interface is checked in §3.11; these steps exercise the server through the remote. Use
a fresh campaign as House Stark (the numbers assume Winterfell was not developed: after §3.4 and
the months of §3.6 its pool holds 13,100 men and their upkeep is 21.9 gold a month).
1. On 1 January, run `...Command:InvokeServer("RaiseArmy", { provinceId = "winterfell" })`.
   **Expected:** `ok = true`, "Raised 10,800 men at Winterfell.", and a Chronicle entry.
2. Run `...Command:InvokeServer("MoveArmy", { armyId = "army_1", provinceId = "moat_cailin" })`.
   **Expected:** "The Army of Winterfell marches to Moat Cailin (27 days)." Resume the clock: the
   army reaches Moat Cailin 27 days later and the Chronicle says so.
3. Run `MoveArmy` to `dragonstone`. **Expected:** `NotEnoughShips`.
4. Open Realm → Finances (before January ends). **Expected:** an "Armies -18.1" line, and "Net
   per month" has fallen from +17.9 to -0.1. When January ends, Settled months shows
   "January 297 AC +25.2 -25.4 = -0.1 -> 139.9" (without the army the expenses would have been
   7.3).
5. In the middle of February run `DisbandArmy` with `{ armyId = "army_1" }`. **Expected:** the men
   return to the levy pools, no gold is refunded, and the February line of Settled months charges
   the army only for the days it was in the field (about half of 18.1).

### 3.11 Armies in the interface (Scenario L, client)
Use a fresh campaign as House Stark (the numbers below assume Winterfell was not developed; after
§3.4 its levy maximum is 13,100). Keep the Output window open: it must show no errors or warnings.
1. **Top bar.** **Expected:** a Troops block next to the treasury reads "38,650" and "Troops",
   without overlapping the date or the buttons on the right (also at a narrow window, where
   the compact layout hides the provinces block). Hover it. **Expected:** "In armies: 0 (0
   armies)", "Levies at home: 33,350 of 33,350", "Garrisons: 5,300 of 5,300", "Ships: 25",
   "Army upkeep: -0.0 gold per month". Click it. **Expected:** the Military tab opens with the
   "Your forces" summary and "No armies in the field".
2. **Raising.** Select Winterfell. **Expected:** the Military section shows "Levies 10,800 /
   10,800" and "Garrison 900 / 900"; the "Raise levies here (10,800 men)" tooltip names Eddard
   Stark (martial 13) and an upkeep of 18.1 gold a month. Click it. **Expected:** a toast "The
   Army of Winterfell has been raised: 10,800 men."; the button reads "Raise levies here (0 men)"
   and is disabled with the reason; "Army of Winterfell 10,800 · Stark" is listed in the
   province; the top bar says "Troops · 1 army".
3. **The token.** **Expected:** a banner in the Stark colour with a dark edge, a small direwolf
   crest and "10,800" in large figures, standing just above Winterfell's castle icon (the icon
   stays visible and clickable). Zoom in and out: the token keeps its size on screen and stays
   anchored to Winterfell. Hover it: the tooltip names the army, House Stark, 10,800 men,
   Commander: Eddard Stark (martial 13), "Idle at Winterfell", morale and supply. Click it.
   **Expected:** the Military tab shows the army (Commander Eddard Stark, Martial 13, troops,
   strength 113.3, upkeep 18.1, pace x1.05, morale and supply bars, composition: northern
   clansmen 4,320, levy spearmen 3,780, archers 1,620, mounted knights 1,080, with their shares)
   and the token gets a gold edge. Left-click the land of Winterfell. **Expected:** the province
   panel opens and the token loses its gold edge (the army is no longer selected; a right-click
   on land now gives no order). Drag the map starting on the token. **Expected:** the map pans;
   neither Winterfell nor the army is selected. Click the token again to select the army.
4. **Moving with the dotted route.** Click Move…. **Expected:** a toast asks for a destination
   and the button reads "Cancel move". Press Esc. **Expected:** "Move order cancelled." (Esc also
   opens the Roblox menu; close it). Click Move… again and right-click any land. **Expected:**
   the same cancellation and no order. Click Move… again, then click the Map tab (and, another
   time, Hide panel). **Expected:** "Move order cancelled."; a click on land now selects the
   province and gives no order. Select the army again, click Move…, then click Moat Cailin's
   land. **Expected:** a toast "The Army of Winterfell marches to Moat Cailin (27 days)."; the
   tab shows "Marching to Moat Cailin — arrives in 27 days"; a dotted gold route runs from
   Winterfell through White Harbor to Moat Cailin with an arrowhead there; the province panel did
   not switch to Moat Cailin. Zoom in and out with the wheel: the dots keep about the same
   spacing on screen and zooming stays smooth. Resume at each speed.
   **Expected:** the token glides smoothly (no jumps between days at any speed), the dots behind
   it disappear, the arrival estimate counts down, the token passes White Harbor without a stop,
   and after 27 days a toast says it has reached Moat Cailin and the route disappears. Pause
   mid-march: the token stops at once and stays put (it may settle back by up to a day or two of
   march, to the day the server has reached).
5. **Re-routing and Stop.** Select the army at Moat Cailin and right-click Winterfell's land.
   **Expected:** it marches back (two legs). While it is on its first leg, right-click The
   Twins. **Expected:** it finishes the leg it is on, and the route is redrawn from that leg's
   end to The Twins. Click Stop. **Expected:** the route shrinks to the current leg and the army
   halts at its end; Stop is then disabled ("has no orders to cancel"). Zoom out until the
   banners hang over neighbouring provinces and right-click the selected army's own banner.
   **Expected:** nothing happens (no order, no error).
6. **Split and merge.** With the army idle, click Split. **Expected:** a second token appears,
   stacked above the first; the counts add up to the original; the new army is led by the next
   best commander (Benjen Stark, martial 11, if he is free). Select the first army. **Expected:** a
   "Merge with Army of Winterfell (…)" button; its tooltip names the joint commander. Click it.
   **Expected:** one token with the full count remains. Split is disabled with a reason while
   the army marches, and for an army under 200 men. Split again, march one half to a
   neighbouring province and let it arrive, then select the other half and right-click the first
   half's banner (wherever the banner hangs, even over another province or the sea).
   **Expected:** the selected army marches to the province where the first half stands.
7. **Supply loss in foreign land.** March the army to The Twins (House Frey). **Expected:**
   while it is on the leg into The Twins and while it stands there, its supply bar drops by 8
   every 5 days (plains); at zero a "has run out of supplies" toast appears, the panel says it is
   starving and the troop count falls every 5 days. March it home: supply recovers by 20 every
   5 days. At speed 3, hover Split or Disband… while the bars move: the tooltip stays up and a
   click always registers (the panel is not redrawn on these ticks; with Winterfell selected in
   the Map tab, its Develop button behaves the same).
8. **Disband.** Click Disband…. **Expected:** the button becomes "Keep the army" and a warning
   says how many men the levy pools can take back; click "Confirm disband". **Expected:** the
   token and its route vanish, the levy pools and the top bar's "Levies at home" rise, and no
   gold is refunded.
9. **Calling the banners.** On Winterfell (with full pools again, or in a new campaign) click
   "Call all levies here". **Expected:** its tooltip lists the armies and men it raises; armies
   appear in every Stark province with levies and march to Winterfell (gathering), each joining
   the army there on arrival (its token disappears and the Winterfell count grows).
10. **Sea crossing.** Start a campaign as House Greyjoy. Raise Pyke's levies (3,700 men, 37
   ships needed of 200), select the army and right-click Lannisport. **Expected:** "(9 days)";
   the token sails straight across the sea and the route is drawn over water. As House
   Lannister, raise Lannisport (11,850 men) and order it to Pyke. **Expected:** the Move…
   tooltip says it needs 119 ships and the house has 39, and the order is refused with "Only a
   voyage reaches Pyke".
11. **Military map mode.** Click Military in the map mode box. **Expected:** provinces shade from
   pale to deep red by men present, the legend reads "Few men" and "Many men (…)", and every
   holding icon shows "Garrison …" under it (under its name when zoomed in). Switch back to
   Houses: the labels disappear.
12. **Saving and loading with a marching army.** Order an army on a long march, save, let it
   arrive, then load. **Expected:** the clock is paused, the token is back where it was at the
   save (not where it was before the load) with its route, and no stale token remains.
13. **Loading another house's campaign.** Save a campaign as House Lannister with an army raised
   at Casterly Rock. Start a new session, lead House Stark, raise Winterfell's levies, select the
   army and click Move…, then load the Lannister save. **Expected:** you lead House Lannister;
   the token of `army_1` shows Lannister's colour and lion with its count, no Stark token remains,
   no army is selected and the next click on land gives no order. In a two-player Local Server
   where player 2 leads Stark, the same load sends the host back to the lobby; choosing another
   house shows only the armies of the loaded campaign, with the right banners and counts.

### 3.12 Mobile layout
1. Use the Device emulator (for example an iPhone landscape profile). **Expected:**
   * the compact layout is used;
   * the panel can be hidden;
   * drag and pinch move the map;
   * a long press on a province shows its tooltip.

Record the results of §3 in this file when performed (date, Studio version, pass/fail notes).
