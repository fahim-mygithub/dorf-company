# Hexcrawl + co-op consensus UI — competitive research & implementation plan

**Date:** 2026-07-20 · **Scope:** the expedition hexcrawl board and the co-op "ring of ayes"
consensus UI — presentation only, no rules changes. **Produced by** the `scholar` research
skill: the `competitive-analysis` pattern (routed: comparative + a theme decision) over
`scholar-core` retrieval, with `scholar-visual` capturing a real reference corpus through
Claude-for-Chrome.

- **Visual deliverable (original mockups, re-themed):** https://claude.ai/code/artifact/3940a7db-b1ac-4979-954f-164b506a3ce0
- **Reference corpus (internal only, not shipped):** `visual-corpus/` — 6 captured cards, indexed by `ui_pattern`.

---

## 0. Capability probe & honesty (scholar-core / scholar-visual)

- `browser_tier: live` (one local Chrome) · `screenshot: live` · `sandbox: live` · `fs: live` ·
  `visual_store: flatfile` (no agentic-vision MCP).
- **Grounding rule honored.** Six UI claims are now **self-captured** (see §1); the rest are
  reported from fan wikis / play knowledge and tagged opinion-tier. Game-*feel* about
  commercial titles is secondhand by construction — we can read pixels, not play the games.
- **The corpus is internal reference only** (scholar-visual §9): captured product UI informs
  direction; it is **not** reproduced in the artifact — every mockup pixel is drawn fresh in
  Dorf's own theme.

## 1. The captured reference corpus (`visual-corpus/`)

| ui_pattern | source | tier | what it proves |
|---|---|---|---|
| threat-telegraph | Slay the Spire — intent icon table | 2 (wiki) | magnitude by icon **size/tint**, not just a number |
| threat-telegraph | Into the Breach — spatial tile telegraph | 1 (live UI) | mark the **target tile itself**, red-hatched, not just an arrow |
| tile-info-panel | Into the Breach — mission node panel | 1 (live UI) | info card **+ board preview + a loud hazard band** ("WIND STORM") |
| map-chrome | Civilization VI — hex HUD | 1 (live UI) | board center, **chrome to the edges**, thin resource ledger, one bright next-action button |
| coop-vote-bar | Among Us — voting grid | 2 (wiki) | show the **whole roster** at once; **time-bound** the decision (44s) |
| coop-vote-bar | WoW — Ready Check | 4 (doc) | leader proposal, **3-state** per-player marker, hard timeout, AFK auto-respond (mechanic, not pixels) |

## 2. Conventions the field has settled (respect, or break deliberately)

**Hexcrawl / route board**
1. **The board is fully visible and each tile answers "what does this cost me?"** Civ VI bakes
   move-cost onto the hovered tile; Civ VII stamps a green yield number + before/after; Slay
   the Spire/FTL make every fork a "what can the deck afford" decision. `[table-stakes]`
   — corroborated across ≥3 independent studios (Firaxis, MegaCrit/Subset, Lavapotion).
2. **Chrome lives on the edges; the board is the hero.** Resource ledger = a thin persistent
   top strip; one bright contextual "what to do next" button (Civ VI). `[table-stakes]`
3. **A tile that matters gets a "what's special about THIS one" band** — objective bonus +
   environmental twist, paired with a board preview (Into the Breach's mission panel). `[performance]`
4. **Threat is drawn onto the board, not just described** — mark the receiving tile; encode
   magnitude by icon weight (ITB spatial hatch; StS intent size/tint). `[performance / delighter]`

**Co-op consensus**
5. **The dominant grammar for shared-risk-with-friends is the ready-check**: a proposal opens,
   every present participant must accept, one decline cancels, a countdown handles AFK
   (Riot accept-check; DRG ready-up; Sea of Thieves place-on-table). `[table-stakes]`
   — corroborated by Riot **+ Ghost Ship + Rare + Blizzard** independently (see §4 adversarial note).
6. **Show the whole roster's state at once, and time-bound the decision** (Among Us). `[performance]`
7. **The commit is a moment** — a per-player marker *lands* (badge/stamp/light), not a silently
   swapped glyph. `[delighter]`

**Key finding — Dorf already landed on the convention.** The "ring of ayes" (`RING_KINDS`,
`_present_seats`, `_refresh_ring`: unanimous present-seat, proposing-is-your-aye, absent seats
struck from the tally) **is** the ready-check convention — independently arrived at, matching
WoW's mechanic almost exactly. **The gap is presentation, not rules.**

## 3. Feature matrices (the read is down the column)

Two separate fields — tile-map exploration and co-op consensus — so two matrices, not one
block-diagonal table. Each is fully populated for its own games; Dorf's row is the todo list.

**3a. Tile-map exploration** (Exhibits A & C)

| Game | Board visible | Payout on tile face | Danger legible on tile | "This tile" info band | Route / path preview |
|---|---|---|---|---|---|
| Civ VI/VII | ✅ | ✅ green yield numbers | ~ via military view | ✅ rich tile tooltip | ✅ full path preview |
| Into the Breach | ✅ | ~ grid / objectives | ✅ red target tiles | ✅ hazard band + preview | ~ move range |
| Slay the Spire / FTL | ✅ node map | ~ reward-type icon | ~ elite / boss icon | ~ event = mystery | ✅ branch highlight |
| Songs of Conquest / HoMM | ✅ | ~ visible pickups | ~ guard stacks | ~ flag / dwelling | ✅ arrow + move cost |
| **Dorf (today)** | ✅ | ❌ **danger only, no payout** | ~ ☠, combat tiles only | ❌ kind emoji + ☠ only | ❌ flag tween, no trail |

**3b. Co-op consensus** (Exhibit B)

| Game | Whole roster shown | Names the stake | Per-seat marker | Timeout / AFK | Commit is a moment |
|---|---|---|---|---|---|
| WoW Ready Check | ✅ party frames | ~ just "ready?" | ✅ check / ? / cross | ✅ auto not-ready | ~ markers flip |
| Riot (LoL/Valorant) | ✅ | — queue pop | ✅ live X/Y accepted | ✅ countdown, cancel-on-decline | ✅ all-accept → launch |
| Deep Rock Galactic | ~ ready lights | ~ mission on the rig | ~ per-player light | ~ host can start | ~ ready-up |
| Sea of Thieves | ~ crew list | ✅ voyage card on the table | ~ vote tokens | — | ~ majority places it |
| Among Us | ✅ portrait grid | — whodunit, not a stake | ✅ vote icons land | ✅ 44s timer | ✅ reveal |
| **Dorf (today)** | ~ crew-bar pips | ❌ terse label | ✅ ✅/✋/⏳/💤 | ~ silent 12s prune | ❌ flat text |

The empty/❌ cells on Dorf's rows **are the todo**.

## 4. Adversarial pass (scholar-core)

- **False-triangulation caught:** LoL + Valorant are both **Riot** — one design lineage, not two
  data points. The "unanimous accept, cancel-on-decline" convention still stands on ≥3
  *independent* studios (Riot + Ghost Ship + Rare + Blizzard).
- **Provenance:** hexcrawl-preview convention ≥3 independent studios; consensus convention ≥4.
  Neither is single-source.
- **Grounding:** the WoW ready-check card is **reported-not-confirmed for the visual** (wiki page
  was text-only); the Among Us card carries the confirmed *visual* for the same pattern.

## 5. Theme recommendation — decision-matrix

**Criteria (weighted for a solo dev shipping to mobile web):** distinctiveness ×3 · on-theme
comedy (the demon-lord-MBA hook) ×3 · readability at portrait/mobile scale ×3 · solo-dev effort
×2 · multiplayer vote legibility ×2 · coherence with shipped combat visuals ×2.

| Option | Distinct | Comedy | Readable | Effort | Vote-legible | Coherent | **Σ** |
|---|---|---|---|---|---|---|---|
| A · War-table cartography (current) | 3 | 2 | 5 | 5 | 4 | 4 | **57** |
| B · Corporate ledger / quarterly board | 5 | 5 | 3 | 2 | 3 | 2 | **57** |
| C · Dwarven stonework delve | 3 | 2 | 4 | 3 | 3 | 3 | **46** |
| **★ D · Fusion — war-table AS a corporate campaign board** | 5 | 5 | 4 | 3 | 4 | 4 | **67** |

**Recommendation: D, the fusion.** Keep the tactical war-table map (it is readable, genre-correct
and already built) and apply the corporate-satire chrome **exactly at the moments the UI
communicates stakes** — the consequence readout styled as an *assay writ / expense line*, the
proposal as a *wax-sealed board sign-off*, treasury+rent as a *P&L ledger strip*, tile payouts as
*line items*. This puts the demon-lord-MBA identity precisely where the research says the gaps are
(baked payout, consequence readout, stake line), and it reuses the shipped Class-Power **coin**
language (steel/gold/arcane) for seats — so it is chrome-and-labeling over existing systems, not a
rebuild. **Trades off:** a little extra art/text polish and a risk of over-cluttering small
screens (mitigate: satire in copy + framing, never in extra widgets). **Runner-up: A** (pure
war-table) — wins if effort must be near-zero, since it needs no theme work. **C loses** — less
distinctive and it drops the MBA hook entirely.

## 6. Gap analysis vs. the shipped code

| Convention | Dorf today | Gap |
|---|---|---|
| Cost/stake baked on tile | `_build_hex_tile` draws kind emoji + ☠ on **combat** tiles only | payout not shown; non-combat tiles carry no stake |
| Consequence preview on select | none — movement is a direct `_on_hex_input` → `_enter_hex` | no "what does this cost me?" beat before committing |
| Edge chrome + resource ledger | treasury/rent in the HUD, but map has a `war-table backdrop` only | no thin persistent ledger tying the board to the rent clock |
| "This tile is special" band | kind + danger only | objective bonus / event twist not surfaced on the tile |
| Consensus presentation | `_refresh_ring` head text + `_ring_label`; crew bar pips ✅/✋/⏳/💤 | flat text; no per-seat identity, no stake spelled out, no visible AFK countdown, no commit "moment" |
| Seat identity | seat colours amber/blue/green/violet | not the shipped coin language; amber/green risk colour-blind collisions |

## 7. Prioritized todo (borrows-from → adapted-as)

**P0 — table-stakes, high leverage**
1. **Bake payout onto reachable/objective hexes.** *Borrows:* Civ VII green-yield numbers.
   *Adapted:* a small mono payout label child on the tile face beside the ☠ pips, `--good`
   green on high-value tiles. *Files:* `hex_tile.gd` (add a label child), `_build_hex_tile`.
   *Kano: table-stakes · Effort: S.*
2. **Consequence readout on tile-select.** *Borrows:* Civ hover-tooltip + ITB mission panel.
   *Adapted:* selecting a reachable hex opens a small "assay writ" panel — distance, ☠ danger,
   on-win payout + `HEX_POST_FIGHT_HEAL`, current crew HP — with a "Propose the march" button;
   the numbers all already exist (`_hex_combat`, `exp_loot_gold`). *Files:* `overworld.gd`
   (`_on_hex_input` → select state before `_enter_hex`). *Kano: performance · Effort: M.*
3. **Spell the stake in the proposal.** *Borrows:* Sea of Thieves voyage card + Civ before/after.
   *Adapted:* extend `_ring_label` / the `_refresh_ring` head to read
   `payout · months · ☠ danger · "dips below rent"` instead of a terse label. *Files:*
   `overworld.gd` (`_ring_label`, `_refresh_ring`). *Kano: table-stakes · Effort: S.*
   ⚠ Keep readout strings to `->` not `→` (the `check_web_glyphs.py` gate rejects U+2192).
4. **Explicit Hold + visible AFK countdown.** *Borrows:* ready-check decline→cancel + timeout.
   *Adapted:* a "✋ Hold — I'm not ready" affordance distinct from counter-proposing, and surface
   the `ABSENT_SEC` grace as a visible auto-hold countdown instead of a silent prune. *Files:*
   `overworld.gd` (crew bar actions, absence sweep). *Kano: table-stakes · Effort: M.*

**P1 — performance / identity**
5. **Coin-portrait crew bar with a stake line + live tally.** *Borrows:* Among Us roster +
   ready-check live X/Y. *Adapted:* redraw each seat as its archetype **coin** (steel/gold/arcane,
   reusing `power_orb.gd` language); a green **wax-seal** stamps on aye; a gold bar fills toward
   unanimity. Snapshot-derived, no new wire event (rides the existing state like the M3b fx
   rider). *Files:* `overworld.gd` crew-bar builder. *Kano: performance/delighter · Effort: M.*
6. **Colour-blind-safe seat identity.** *Borrows:* accessibility best practice. *Adapted:* pair
   each seat colour with a shape/glyph (the coin metal + class emoji already do this) so amber vs
   green is never the only signal. *Kano: table-stakes · Effort: S.*
7. **Edge ledger tying the board to the rent clock.** *Borrows:* Civ VI top resource ribbon.
   *Adapted:* a thin persistent treasury→rent strip above the war-table so the board reads as a
   *quarterly expedition* (the corporate-fusion theme). *Files:* `overworld.gd` HUD/hexcrawl.
   *Kano: performance · Effort: M.*

**P2 — delighters / defer**
8. **"This tile is special" band on select** — objective bonus / event twist surfaced on the
   tile (ITB hazard band). *Effort: M.*
9. **Ghost path-preview trail** for the 🚩 march (the flag already tweens; draw the route as
   fading motes). *Borrows: Civ path preview. Effort: S. Defer.*
10. **Combat cross-over** (out of hexcrawl scope, noted): StS size/tint intent magnitude + ITB
    target-tile marking for `threat_arrows.gd` / Vulnerable-Taunt reroute. *Defer to a combat pass.*

## 8. Coverage gaps & next captures (scholar honesty)

- Reddit player-sentiment threads and GDC design talks were **not** deep-fetched (time-boxed).
- Civ VII community-reception data was thin.
- Small-party hexcrawl neighbours (Wartales / Battle Brothers / Songs of Conquest) use **non-hex**
  node/free-roam overworlds — they informed the party-travel read but are not hex evidence.
- **Two worthwhile next captures:** (a) a node route-planner map-chrome (Slay the Spire's branching
  map) as a second map flavour closest to the expedition layer; (b) a live WoW ready-check widget
  for the 3-state party-frame pixels (only the mechanic is confirmed, not the visual).
