# Game Design

## Vision

You govern a noble dynasty in a living feudal world inspired by Crusader Kings III's *A Game of
Thrones* mod and by Stellaris. Power comes from lands, gold, legitimacy, relationships and
judgment, not from an avatar. Every system feeds the others:
* a rich house can be politically isolated;
* a beloved ruler can be too poor to defend the realm;
* a small house can rise through diplomacy.

The world acts on its own: AI rulers pursue their own goals under the same rules as players.

Design pillars:
* A living simulated world.
* Characters matter.
* The realm is a network of obligations.
* Decisions have traceable consequences.
* Complexity stays readable.
* Stories emerge from the simulation.

## Phase 1 slice: what the player does

1. Choose one of ten houses. Each card shows its real starting position.
2. Read the realm: the map, your provinces (thin gold outlines) and your neighbours.
3. Start the clock. Every month, the server settles income and expenses.
4. Invest gold to develop provinces, trading money now for income later.
5. Send envoys to improve relations with neighbours and rivals.
6. Raise your levies into armies and march them across the realm, paying their upkeep.
7. Watch AI houses develop their lands and court each other.
8. Save the campaign and load it later.

The first ten minutes teach the loop: gold comes from developed land, development costs gold,
and relations cost gold and fade without upkeep.

## Calendar and speed

* Dates are day/month/year AC. There are 12 months, 365 days and no leap years.
* The campaign starts on 1 January 297 AC, paused.
* Speeds:

  | Speed | Seconds per day | Seconds per month |
  |---|---|---|
  | 1 (Normal) | 0.40 | ~12 |
  | 2 (Fast) | 0.15 | ~4.5 |
  | 3 (Very fast) | 0.05 | ~1.5 |

* Economy, levy refills, relation drift and AI decisions are processed once at the end of each
  month. Armies move every day; their supply and morale change every 5 days.

## Economy (formulas in `Shared/Rules/EconomyRules.luau`, constants in `GameConfig.Economy`)

```
Province income   = baseTax × (1 + 0.20 × (development − 1)) × terrain multiplier × holding multiplier
House tax income  = Σ income of owned, unoccupied provinces
                    × (1 + 0.015 × ruler stewardship + trait tax bonuses)
Monthly expenses  = court upkeep × (1 + trait court modifiers)
                    + Σ holding garrison upkeep + 0.08 × development, per province
                    + army upkeep (see Military)
Net               = tax income − expenses, applied to the treasury once per month (rounded to 0.01)
Development cost  = round(20 × 1.30^(development − 1) × terrain cost multiplier), development 1..10
```

Terrain and holding modifiers:

| Terrain | Tax | Development cost |
|---|---|---|
| Farmlands | ×1.15 | ×0.95 |
| Coast | ×1.05 | ×1.00 |
| Plains | ×1.00 | ×1.00 |
| Hills | ×0.90 | ×1.15 |
| Island | ×0.90 | ×1.20 |
| Forest | ×0.85 | ×1.10 |
| Desert | ×0.80 | ×1.20 |
| Mountains | ×0.75 | ×1.35 |
| Marsh | ×0.70 | ×1.25 |

| Holding | Tax | Garrison upkeep |
|---|---|---|
| City | ×1.20 | 0.4 |
| Port | ×1.15 | 0.5 |
| Castle | ×1.00 | 0.6 |
| Fortress | ×0.80 | 0.9 |

Consequences:
* Development has diminishing returns. Costs grow by 30% per level while gains are linear, so the
  first levels on rich farmland pay back within about three years, and late levels on poor
  mountains never do.
* The province panel shows the exact gain and payback period before you buy.
* A treasury can go negative only through upkeep (debt). A negative treasury triggers a crisis
  event, and nothing can be bought until it recovers.
* Occupied provinces produce nothing for their owner. This is the hook for war (Phase 2, battles
  and sieges).

Starting positions (from `tests/house_report.luau`):

| House | Tier | Ruler | Provinces | Dev | Treasury | Income | Expenses | Net/month |
|---|---|---|---|---|---|---|---|---|
| House Arryn | great | Jon Arryn | 3 | 10 | 160 | 20.5 | 5.8 | +14.7 |
| House Baratheon | great | Robert Baratheon | 6 | 20 | 110 | 40.3 | 13.0 | +27.3 |
| House Bolton | minor | Roose Bolton | 1 | 3 | 85 | 3.6 | 2.3 | +1.3 |
| House Frey | minor | Walder Frey | 1 | 4 | 180 | 7.3 | 2.3 | +5.1 |
| House Greyjoy | great | Balon Greyjoy | 2 | 5 | 90 | 6.5 | 4.6 | +1.9 |
| House Lannister | great | Tywin Lannister | 4 | 18 | 320 | 38.1 | 8.0 | +30.1 |
| House Martell | great | Doran Martell | 4 | 13 | 170 | 15.5 | 6.6 | +8.9 |
| House Stark | great | Eddard Stark | 5 | 14 | 140 | 25.2 | 7.3 | +17.9 |
| House Tully | great | Hoster Tully | 3 | 9 | 130 | 17.1 | 5.4 | +11.7 |
| House Tyrell | great | Mace Tyrell | 5 | 23 | 230 | 51.0 | 8.5 | +42.5 |

Each house plays differently:
* **Baratheon** holds the capital, but King Robert's Profligate trait inflates court costs by 35%.
* **Lannister and Tyrell** are rich.
* **Greyjoy and Bolton** are poor and must spend carefully.
* **Frey** has a small realm but hoarded gold.

## Diplomacy (formulas in `Shared/Rules/DiplomacyRules.luau`, constants in `GameConfig.Diplomacy`)

* **Symmetric house relations:** one score per pair of houses, from −100 to +100, with a historical
  baseline from the bookmark. Each baseline has a reason (e.g. "Princess Elia was murdered during
  the Lannister sack of King's Landing").
* **Tiers:**

  | Tier | Score |
  |---|---|
  | Friendly | ≥ 50 |
  | Cordial | ≥ 10 |
  | Neutral | ≥ −9 |
  | Cold | ≥ −49 |
  | Hostile | below −49 |

* **Drift:** every month, each relation moves 1 point toward its baseline. Goodwill fades unless
  maintained, and old wounds slowly reassert themselves.
* **Improve Relations** (send an envoy):
  * Costs 25 gold.
  * Gain = 8 + ⌊0.5 × sender's ruler Diplomacy⌋ + the sender's trait modifiers (Gregarious +3,
    Honest +2, Proud −2, Wrathful −2, Shy −2, Cruel −3, Deceitful −1) + the recipient's
    modifiers (Proud −2). The gain is never below 3, and the result is clamped to 100.
  * There is a 6-month cooldown per sender and target pair.
  * Example: Eddard Stark (Diplomacy 8, Honest) courting Tywin Lannister (Proud):
    8 + 4 + 2 − 2 = +12, moving relations from −10 to +2.
* Relations do not yet trigger treaties. They are the foundation for alliances, marriages and AI
  acceptance decisions (Phase 4 gives the AI personalities and stances, Phase 8 treaties).

## Military (formulas in `Shared/Rules/MilitaryRules.luau` and `MovementRules.luau`, constants in `GameConfig.Military`, units in `Data/Military/UnitDefinitions.luau`)

Every province musters **levies**, the men who can be raised into armies, and keeps a
**garrison**, the men who hold its walls and never march. Ships come from coasts, islands and
ports. Armies are raised from levies, march over the province graph and cost gold every month.
There are no battles, sieges or wars yet, and the AI does not raise armies yet.

### Levies, garrisons and ships

```
Levy maximum      = (1,200 + 1,700 × development) × holding levy × terrain manpower × region manpower,
                    rounded to 50 men
Garrison maximum  = holding garrison base + holding garrison per development × development,
                    rounded to 10 men
Ships             = round((terrain ships + holding ships per development) × development × region naval)
Monthly refill    = ceil(8% of the levy maximum) levies and ceil(15% of the garrison maximum)
                    garrison troops, never above the maximum; occupied provinces do not refill
```

A house's fleet is the sum of the ships of the provinces it holds (owned and not occupied). Every
pool starts full. Raising empties a province's levy pool; it takes about a year to refill.

**Buildings hook.** Both maximums also take pool modifiers from the province's state
(`MilitaryRules.poolModifiers`): a levy multiplier, and a garrison multiplier plus flat garrison
men. No buildings exist yet, so they are ×1, ×1 and +0. The buildings phase (Phase 5) fills them
in, for example a barracks for more levies or curtain walls for a larger garrison, and every pool,
view and refill follows. If a balance change lowers a maximum, pools (and an army's morale and
supply) above it are lowered to it, in play and when a save is loaded.

| Terrain | Movement cost | Manpower | Ships per development | Supply drain |
|---|---|---|---|---|
| Plains | ×1.0 | ×1.0 | 0 | ×1.0 |
| Farmlands | ×1.0 | ×1.25 | 0 | ×0.8 |
| Forest | ×1.3 | ×0.85 | 0 | ×1.1 |
| Hills | ×1.25 | ×0.9 | 0 | ×1.1 |
| Mountains | ×1.7 | ×0.8 | 0 | ×1.5 |
| Marsh | ×1.8 | ×0.6 | 0 | ×1.4 |
| Coast | ×1.0 | ×1.0 | 2 | ×1.0 |
| Island | ×1.0 | ×0.8 | 4 | ×1.2 |
| Desert | ×1.4 | ×0.8 | 0 | ×1.6 |

| Holding | Levies | Garrison base | Garrison per development | Ships per development |
|---|---|---|---|---|
| Castle | ×1.0 | 500 | 100 | 0 |
| Fortress | ×0.5 | 1,500 | 300 | 0 |
| City | ×0.6 | 1,200 | 250 | 0 |
| Port | ×0.8 | 600 | 120 | 3 |

| Region | Manpower | Naval |
|---|---|---|
| The North | ×1.35 | ×1 |
| The Iron Islands | ×1.0 | ×10 |
| The Riverlands | ×1.05 | ×1 |
| The Vale of Arryn | ×2.2 | ×1 |
| The Westerlands | ×1.3 | ×1.3 |
| The Crownlands | ×0.9 | ×1.6 |
| The Stormlands | ×1.15 | ×1 |
| The Reach | ×1.4 | ×1.6 |
| Dorne | ×1.15 | ×1 |

Fortresses keep big garrisons but raise few levies; cities raise fewer levies (and pay more tax).
The constants are calibrated to the lore of 297 AC. At the bookmark (full pools):

| House | Levies | Garrisons | Total men | Ships |
|---|---|---|---|---|
| Tyrell | 57,100 | 6,730 | 63,830 | 67 |
| Lannister | 36,700 | 5,620 | 42,320 | 39 |
| Baratheon (Crownlands and Stormlands) | 33,350 | 6,910 | 40,260 | 67 |
| Stark | 33,350 | 5,300 | 38,650 | 25 |
| Arryn | 32,200 | 4,100 | 36,300 | 25 |
| Martell | 20,850 | 4,900 | 25,750 | 15 |
| Tully | 18,550 | 2,560 | 21,110 | 15 |
| Greyjoy | 8,750 | 1,500 | 10,250 | 200 |
| Frey | 8,400 | 900 | 9,300 | 0 |
| Bolton | 7,650 | 800 | 8,450 | 0 |

Winterfell (castle, plains, the North, development 4) musters (1,200 + 6,800) × 1.35 = 10,800
levies and a garrison of 900.

### Units

Every levy is split among unit types by the raising house's **composition** (largest remainder,
so the head count is exact). Each great house has one unique unit; the minor houses use the
default composition.

| Unit | Class | Attack | Defence | Morale | Speed | Upkeep | Siege | Special |
|---|---|---|---|---|---|---|---|---|
| Levy spearmen | spear | 8 | 10 | 0 | 1.0 | 1.0 | 0 | |
| Archers | archer | 10 | 6 | 0 | 1.0 | 1.1 | 0 | |
| Mounted knights | cavalry | 14 | 9 | 5 | 1.35 | 2.0 | 0 | |
| Siege engines | siege | 2 | 3 | 0 | 0.85 | 3.0 | 10 | |
| Northern clansmen | spear | 11 | 11 | 10 | 1.05 | 1.0 | 0 | Stark; forest ×1.3, hills ×1.15, the North ×1.25 |
| Lannister heavy knights | cavalry | 22 | 14 | 10 | 1.15 | 3.0 | 0 | Lannister |
| Ironborn reavers | spear | 15 | 8 | 15 | 1.1 | 1.2 | 0 | Greyjoy; coast and island ×1.2, raids and landings ×1.4 |
| Reach cavalry | cavalry | 12 | 7 | 0 | 1.35 | 1.3 | 0 | Tyrell (cheap and numerous) |
| Dornish spearmen | spear | 11 | 11 | 5 | 1.25 | 1.1 | 0 | Martell; desert ×1.35, mountains ×1.15 |
| Knights of the Vale | cavalry | 24 | 18 | 15 | 1.15 | 3.5 | 0 | Arryn (elite) |
| River archers | archer | 12 | 7 | 5 | 1.0 | 1.2 | 0 | Tully; river defence ×1.4 |
| Stormland warhammers | spear | 18 | 9 | 10 | 0.95 | 1.8 | 0 | Baratheon (high damage) |

Counters (damage multipliers for the battles that come with war): spears ×1.5 against cavalry, cavalry ×1.5
against archers, archers ×1.5 against spears, siege engines ×4 against walls. The terrain,
region and situation multipliers are also combat hooks for later phases.

| House | Composition |
|---|---|
| Stark | 35% levy spearmen, 15% archers, 10% mounted knights, 40% northern clansmen |
| Lannister | 40% levy spearmen, 20% archers, 10% mounted knights, 25% heavy knights, 5% siege engines |
| Greyjoy | 25% levy spearmen, 15% archers, 60% ironborn reavers |
| Tyrell | 35% levy spearmen, 20% archers, 40% Reach cavalry, 5% siege engines |
| Martell | 20% levy spearmen, 25% archers, 10% mounted knights, 45% Dornish spearmen |
| Arryn | 45% levy spearmen, 20% archers, 10% mounted knights, 25% Knights of the Vale |
| Tully | 45% levy spearmen, 10% archers, 15% mounted knights, 30% river archers |
| Baratheon | 35% levy spearmen, 20% archers, 15% mounted knights, 25% warhammers, 5% siege engines |
| Frey, Bolton (default) | 60% levy spearmen, 25% archers, 15% mounted knights |

### Armies

```
Upkeep (gold/month) = Σ (men / 1,000 × unit upkeep) × 1.5; it accrues for every day the army is in
                      the field and is settled monthly: the month's charge is the sum of each
                      day's monthly upkeep divided by the days of the month
Starting morale     = 60 + head-count-weighted unit morale bonus, at most 100; supply starts at 100
Strength (display)  = Σ (men × (attack + defence) / 2) / 1,000 × (1 + 0.02 × (commander martial − 10))
Army speed          = men / Σ (men / unit speed): the pace of the army's average man (a
                      head-count-weighted harmonic mean), so swift units speed an army up in
                      proportion to their numbers and a few siege engines slow it only a little
```

Pace of each house's levy: Martell ×1.13 (Dornish spearmen), Tyrell ×1.10 (Reach cavalry), Arryn
and Greyjoy ×1.06, Stark and Lannister ×1.05, Tully and the minor houses ×1.04, Baratheon ×1.02
(warhammers and siege engines).

* **Raise levies:** raises every available levy of a province the house holds (at least 100
  men) into one army, named after the holding: "Army of Winterfell". A house keeps at most 12
  armies.
* **Call all levies:** every held province with at least 100 levies raises an army at once. The
  armies raised elsewhere march to the rally province and merge into the army waiting there.
  A province that cannot reach the rally (an island without enough ships) keeps its levies.
* **Commanders:** the best available adult (16 or older) of the house who leads no other army:
  highest martial, then the ruler, then by id. Children never lead; with nobody left an army is
  leaderless. Eddard Stark (martial 13) leads the first northern army, Benjen (11) the second.
* **Split** an idle army of at least 200 men: every unit is halved (the odd man stays), each half
  keeps at least 100 men, morale and supply are copied, and the new half gets the next best
  commander.
* **Merge** two idle armies in the same province: units are added, morale and supply become
  head-count-weighted averages, and the commander with the higher martial keeps command.
* **Disband:** the men return to the levy pools of the house's held provinces, shared by each
  pool's shortfall and never above its maximum. Men the pools cannot take back are lost. Nothing
  is refunded.
* **Upkeep:** the Winterfell levy costs 18.06 gold a month; Stark's whole levy about 56, against
  a net income of 17.9. Raising everything bankrupts a house within months, so armies are raised
  for a purpose and sent home afterwards. Upkeep is paid for the days an army is in the field:
  one disbanded after 15 days of January costs 15/31 of a month (8.74 gold for the Winterfell
  levy), so sending an army home just before the month ends saves nothing.

### Movement

```
Land leg (days) = ceil(max(1, distance / 12 × connection cost × destination terrain movement cost
                                / army speed))
Sea leg (days)  = ceil(max(1, distance / 30))     (terrain and unit speed do not matter at sea)
Connection cost = road ×0.8, river ×1.0, mountain pass ×1.6, wilderness ×1.5
Ships needed    = ceil(men / 100)
```

* Distances are between the provinces' map positions. Orders take the fastest route in days;
  between equally fast routes, the alphabetically first one.
* Sea lanes are used only when the house's whole fleet could carry the army; when the
  destination can only be reached by sea, the order is refused ("not enough ships").
* At sea the army needs that many **free** ships: the fleet minus the ships carrying the house's
  other armies at sea. Otherwise it waits in port and sails as soon as enough ships are free.
* Examples: Winterfell's levy (pace ×1.05) reaches Moat Cailin in 27 days through White Harbor
  (13 days by road, then 14 into the marsh of the Neck); Pyke's ironborn sail to Lannisport in 9
  days; Stark's 25 ships cannot carry 10,800 men to Dragonstone.
* A new order keeps the leg under way and replaces the rest of the route; **Stop** halts the army
  at the end of the current leg (a waiting army simply stays).

### Supply, morale and attrition (every 5 days)

* An army's ground is its leg's destination while marching, otherwise the province it stands in.
* On ground its house controls: supply +20 and morale +2 (up to 100).
* At sea: no change.
* Anywhere else it forages: supply −ceil(8 × terrain supply drain), so −8 on plains, −12 in the
  mountains and −13 in the Dornish desert.
* At zero supply the army starves: it loses ceil(3% of its men), spread over its units by head
  count, and 5 morale; the first time, the house is alerted. An army reduced below 50 men
  deserts entirely.

## AI rulers (`GameConfig.AI`)

* AI houses are evaluated monthly. Each house's personality is a base value plus its ruler's
  trait weights. For example, Ambitious raises investment appetite, and Greedy keeps three
  extra months of reserve.
* An AI house keeps a cash reserve of `reserveMonths × monthly expenses` and never spends below
  it.
* **Develop:** the AI picks the province with the best payback. Normally it accepts paybacks up
  to 90 months; up to 360 months when it could pay six times over.
* **Envoys:** the AI courts houses below +25 relations, preferring neighbours and worse
  relations. It never courts blood feuds, meaning baselines below −50 (Martell–Lannister,
  Greyjoy–Baratheon).
* The AI does not raise armies yet. Military AI arrives with war.
* All randomness comes from the campaign's seeded RNG.

Balance over a 30-year all-AI run (`tests/balance_report.luau`):
* Every treasury stays positive.
* AI houses develop actively for the first decade and make about 170 developments.
* Relations move but stay plausible.
* Late-game gold accumulates because the AI does not yet raise armies and there are no buildings.
  Army upkeep, wars and buildings are the intended gold sinks.

## Characters (Phase 1 scope)

* There are 52 seed characters across ten houses, with real family links: parents, spouses,
  deceased ancestors, and acknowledged bastards named by culture ("Jon Snow", "Ramsay Snow",
  "Walder Rivers").
* Ages derive from birth dates and the campaign date.
* Rulers matter now:
  * Stewardship raises tax income.
  * Diplomacy improves envoys.
  * Martial decides who leads the house's armies and improves their strength rating.
  * Traits modify taxes, court costs, envoys and AI personality.
* Births, deaths, marriages and succession arrive in Phase 6.

## The map

* 34 provinces across nine regions.
* Connections are roads, rivers, sea lanes, mountain passes and wilderness.
* Real chokepoints:
  * Moat Cailin, the only land route north of the Neck
  * the Bloody Gate
  * the Golden Tooth
  * Kingsgrave (Prince's Pass)
  * Yronwood (the Boneway)
* The drawing (Data/World/MapData.luau, a single configuration file):
  * a political map of the great houses of 297 AC in a 1000 x 1900 viewBox, traced from a
    reference map: Stark, Arryn, Tully, Greyjoy, Lannister, Tyrell, Baratheon and Martell, each
    with its palette. The Targaryens are in exile: the Crownlands and Dragonstone are the crown's,
    drawn as House Baratheon's royal demesne ("THE CROWN") in their own gold;
  * every region is split into 4-10 unnamed sub-territories shaded from its house's palette;
    each sub-territory belongs to one of the game's 34 provinces, so clicking land selects it;
  * Beyond the Wall (flat grey), the Wall (a black band across the continent at y 80-130), the
    Gift (black, just south of it) and the Stepstones;
  * a heater-shield crest per great house (flat vector sigils), two-line "HOUSE / NAME" labels,
    and icons for seats (castle), cities (house), ports (anchor) and landmarks (tower).
* The drawing is presentation only. Who holds a province is game state: the Freys and Boltons
  hold provinces inside the Tully and Stark regions, which the Realm map mode shows.
* Map modes:
  * Houses (default): the great houses' palettes.
  * Realm: the colour of the house that holds each province today.
  * Relations: green to grey to red, relative to your house.
  * Wealth: monthly income.
  * Terrain: the land's own muted colours, region by region (the same palette as the atlas look
    below).
  * Military: from pale to deep red by the men present in each province (its
    garrison plus the armies standing there), relative to the province with the most. Each
    holding icon also gets a "Garrison 1,800" label, shown from the zoom at which icons appear.
* Gold outlines: thin around your own provinces, thick around the selected one.
* Framing and zoom levels (all tunable in UI/MapConfig.luau; the levels count from the
  whole-map view, so it is political on every screen): the whole-map view fits Westeros,
  from Beyond the Wall to Dorne, to the height of the map area, and the view never zooms out past
  it or pans off into empty sea. From afar the map is political: crests and great-house labels,
  with location icons from a medium zoom and their names from a closer one. Zooming in crosses a
  blend zone where the house colours, crests and house labels fade into an atlas of the land, and
  the black borders become thin kingdom borders in each house's colour; hovering a region in the
  atlas outlines it and gives it a faint fill in that colour. Settlements will appear in the atlas
  with the later parts of the map upgrade. The Houses and Terrain modes blend; the data modes
  (Realm, Relations, Wealth, Military) keep their colours at every zoom. A toggle hides the thin
  sub-territory borders of the political map.
* Hovering land brightens the sub-territory, outlines the whole region and shows a tooltip with
  the region, its great house and the province's current owner, development and income.

## Interface

* **Look:**
  * dark charcoal and burgundy chrome
  * parchment panels with ink text and gold accents
  * Merriweather headings, Grenze Gotisch title, Source Sans body text
  * procedural heraldic shields: field colour, division and monogram, with no third-party art
* **Top bar:**
  * house shield, name, ruler and age
  * treasury, with a tooltip giving the full monthly budget line by line (army upkeep included)
  * troops: the house's total men; the tooltip breaks them down into armies, levies at home (of
    their maximum), garrisons, ships (and ships at sea) and army upkeep per month. A click opens
    the Military tab.
  * provinces and total development (hidden in the compact layout)
  * date
  * speed controls
  * Campaign menu: save, load, storage status, and dev tools in Studio
* **Tabs:**
  * **Map:** the province panel. Its Military section shows the province's levies and garrison
    (each of its maximum), its ships, and the armies standing there (a click selects one). On a
    province you hold it offers "Raise levies here (N men)" and "Call all levies here", with the
    commander and the upkeep in the tooltip.
  * **Realm:** ruler, skills, traits, family, finances (army upkeep included), settled ledger,
    holdings.
  * **Military:** your forces (total men, men in armies, levies, garrisons, ships, army upkeep),
    the list of your armies with their orders, and the selected army: commander and martial,
    troops, strength, upkeep, pace, morale and supply bars, its orders with the arrival estimate,
    and its composition (unit, class, men, share). Your own army has Move…, Stop, Split, one
    "Merge with …" button for every other idle army of yours in the same province, and Disband…
    (a second click confirms it and says how many men the levy pools can take back). Another
    house's army is shown read-only.
  * **Diplomacy:** houses sorted by relation, the reason for each baseline, the envoy action with
    its preview.
  * **Chronicle:** the event log.
* **Armies on the map:**
  * Each army is a token in its house's map colour with a dark edge, a small crest and its troop
    count in large figures. Tokens keep the same size on screen at every zoom, stand just above
    the province's holding icon (so the icon stays visible), and stack when several armies stand
    together. The selected army has a gold edge.
  * Armies glide between provinces. The server sends only the current leg and the day it ends;
    the client places the token by day, moving it smoothly between updates, and snaps it into
    place when the clock is paused.
  * Your own marching armies, and the selected army, show their route as a line of dots ending
    in an arrowhead. The dots behind an army disappear as it advances.
  * Hovering a token shows its name, men, commander and orders with the arrival estimate;
    clicking selects it and opens the Military tab. Dragging the map by a token pans it without
    selecting the army.
* **Giving orders:** Move… puts the army in move mode: the next click on land (or a holding icon)
  is its destination, and a click on another army's token sends it where that army stands. A
  toast confirms the march and its length in days. A right-click, Esc (or anything else that
  opens the Roblox menu), Cancel move, leaving the Military tab or hiding the panel ends move mode
  without an order. Outside move mode, a right-click on land marches the selected army there, a
  right-click on another army's token marches it to that army's province (never to the land drawn
  under the raised banner; a right-click on its own token does nothing), and a left click on the
  map selects the province (or clears the selection, on the sea) and deselects the army, so no
  hidden selection keeps taking right-click orders. Loading a campaign deselects the army and
  cancels move mode. Orders take the fastest route, by sea only when the fleet can carry the
  whole army. An army waiting for free ships reads "Waiting for ships at …"; ordering it to the
  port it waits in is refused (Stop cancels the voyage).
* **Disabled buttons always say why:**
  * insufficient gold
  * cooldown, and when it ends
  * not your province, or occupied
  * too few levies to raise an army, or levies that cannot reach the rally province
  * the limit of 12 armies
  * an army that cannot split (marching, or halves under 100 men), merge (marching) or stop (no
    orders)
  * host-only actions
* **Notifications:** toasts appear only for important events: rejections, envoys to your court,
  treasury crises, saves and loads, armies raised, levies called, arrivals, starving armies and
  desertions, and confirmations of march orders. Routine events (splits, merges, disbanding) go
  to the Chronicle.
* **Responsive layout:**
  * One UI scale fits any screen.
  * A compact layout narrows the rail and the panel.
  * The panel can be hidden.
  * Map controls work with touch (drag, pinch), mouse (drag, wheel) and buttons.

## Assumptions that affect implementation

* In Phase 1 all ten houses are independent actors; historically they are vassals of the Iron
  Throne. The feudal hierarchy is Phase 7.
* Characters married into houses not on the map (Olenna Redwyne, Joanna Lannister) are listed
  under their marital house. Separate dynasty and birth-house fields arrive in Phase 6.
* There are no leap years. AC dating applies throughout.
* All campaign state is public to all players in Phase 1. The per-viewer `Snapshot` exists so
  that secrets and hidden treasuries can be added later.
* Persistence is one save slot per host. Persistent shared campaigns are Phase 9.
