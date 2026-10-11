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
2. Read the realm: the map, your provinces (gold outlines) and your neighbours.
3. Start the clock. Every month, the server settles income and expenses.
4. Invest gold to develop provinces, trading money now for income later.
5. Send envoys to improve relations with neighbours and rivals.
6. Watch AI houses develop their lands and court each other.
7. Save the campaign and load it later.

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

* Economy, relation drift and AI decisions are processed once at the end of each month.

## Economy (formulas in `Shared/Rules/EconomyRules.luau`, constants in `GameConfig.Economy`)

```
Province income   = baseTax × (1 + 0.20 × (development − 1)) × terrain multiplier × holding multiplier
House tax income  = Σ income of owned, unoccupied provinces
                    × (1 + 0.015 × ruler stewardship + trait tax bonuses)
Monthly expenses  = court upkeep × (1 + trait court modifiers)
                    + Σ holding garrison upkeep + 0.08 × development, per province
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
* Occupied provinces produce nothing for their owner. This is the hook for Phase 5 war.

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
  acceptance decisions in Phase 4.

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
* All randomness comes from the campaign's seeded RNG.

Balance over a 30-year all-AI run (`tests/balance_report.luau`):
* Every treasury stays positive.
* AI houses develop actively for the first decade and make about 170 developments.
* Relations move but stay plausible.
* Late-game gold accumulates because Phase 1 has no armies or buildings to spend it on. These are
  the intended gold sinks for Phases 5–6.

## Characters (Phase 1 scope)

* There are 52 seed characters across ten houses, with real family links: parents, spouses,
  deceased ancestors, and acknowledged bastards named by culture ("Jon Snow", "Ramsay Snow",
  "Walder Rivers").
* Ages derive from birth dates and the campaign date.
* Rulers matter now:
  * Stewardship raises tax income.
  * Diplomacy improves envoys.
  * Traits modify taxes, court costs, envoys and AI personality.
* Births, deaths, marriages and succession arrive in Phase 2.

## The map

* 34 provinces across nine regions.
* Connections are roads, rivers, sea lanes, mountain passes and wilderness.
* Real chokepoints:
  * Moat Cailin, the only land route north of the Neck
  * the Bloody Gate
  * the Golden Tooth
  * Kingsgrave (Prince's Pass)
  * Yronwood (the Boneway)
* Map modes:
  * Realm: owner colours, with gold outlines on your own provinces.
  * Relations: green to grey to red, relative to your house.
  * Wealth: monthly income.
  * Terrain.
* Holding markers:
  * square: castle
  * diamond: fortress
  * circle: city
  * ring: port
* The badge on each marker shows its development level.

## Interface

* **Look:**
  * dark charcoal and burgundy chrome
  * parchment panels with ink text and gold accents
  * Merriweather headings, Grenze Gotisch title, Source Sans body text
  * procedural heraldic shields: field colour, division and monogram, with no third-party art
* **Top bar:**
  * house shield, name, ruler and age
  * treasury, with a tooltip giving the full monthly budget line by line
  * provinces and total development
  * date
  * speed controls
  * Campaign menu: save, load, storage status, and dev tools in Studio
* **Tabs:**
  * **Map:** the province panel.
  * **Realm:** ruler, skills, traits, family, finances, settled ledger, holdings.
  * **Diplomacy:** houses sorted by relation, the reason for each baseline, the envoy action with
    its preview.
  * **Chronicle:** the event log.
* **Disabled buttons always say why:**
  * insufficient gold
  * cooldown, and when it ends
  * not your province
  * host-only actions
* **Notifications:** toasts appear only for important events (rejections, envoys to your court,
  treasury crises, saves and loads). Routine events go to the Chronicle.
* **Responsive layout:**
  * One UI scale fits any screen.
  * A compact layout narrows the rail and the panel.
  * The panel can be hidden.
  * Map controls work with touch (drag, pinch), mouse (drag, wheel) and buttons.

## Assumptions that affect implementation

* In Phase 1 all ten houses are independent actors; historically they are vassals of the Iron
  Throne. The feudal hierarchy is Phase 3.
* Characters married into houses not on the map (Olenna Redwyne, Joanna Lannister) are listed
  under their marital house. Separate dynasty and birth-house fields arrive in Phase 2.
* There are no leap years. AC dating applies throughout.
* All campaign state is public to all players in Phase 1. The per-viewer `Snapshot` exists so
  that secrets and hidden treasuries can be added later.
* Persistence is one save slot per host. Persistent shared campaigns are Phase 7.
