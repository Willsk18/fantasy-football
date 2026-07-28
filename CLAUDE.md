# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A personal fantasy football draft board for the 2026 season, half-PPR scoring. One
self-contained HTML file, deployed as a static site, with optional cross-device sync
through Supabase.

## Commands

There is no build, no package manager, no test suite, and no linter. `index.html` is
the entire application.

| Task | How |
|---|---|
| Run locally | Open `index.html` in a browser (`start index.html`). `file://` works fully. |
| Deploy | `git push origin main` — GitHub Pages rebuilds in ~1 min |
| Live site | https://willsk18.github.io/fantasy-football/ |
| Check deploy | `curl -s https://api.github.com/repos/Willsk18/fantasy-football/actions/runs \| grep conclusion` |

**No JS runtime is installed on this machine** — no `node`, no `python`. You cannot
syntax-check or unit-test changes locally. Verify in a browser, and check the console.
A crude delimiter-balance check over the script block catches gross syntax errors:

```bash
awk '/^<script>$/{f=1;next} /^<\/script>$/{f=0} f' index.html > /tmp/board.js
awk '{for(i=1;i<=length($0);i++){c=substr($0,i,1); if(c=="{")b++; else if(c=="}")b--; else if(c=="(")p++; else if(c==")")p--}} END{print "braces:",b+0" parens:",p+0}' /tmp/board.js
```

The Supabase functions can be exercised directly without the UI:

```bash
U="https://wffabvvnojsilsyzfdba.supabase.co"; K="sb_publishable_eF231so047SnPtEaDDScVg_9LwkNvsc"
curl -s -X POST "$U/rest/v1/rpc/board_get" -H "apikey: $K" -H "Content-Type: application/json" \
  -d '{"p_code":"aaaa-bbbb-cccc"}'
```

## Architecture

Everything lives in `index.html`: styles, the ~220-entry `PLAYERS` array, and all logic.
The single external runtime dependency is SortableJS from cdnjs (drag-to-reorder), which
means reordering needs an internet connection. `supabase-setup.sql` is reference material,
already applied to the live project — it is not run by anything at runtime.

### One ranking, six views

This is the central invariant and the thing most likely to be broken by a careless edit.

`store.master` is a flat array of every player id in Overall order. It is the *only*
ordering that exists. The six tabs (Overall / QB / RB / WR / TE / Flex) are filtered
views of it via `tabIds(tab)`, so a player's position relative to his peers is identical
in every tab.

When the user reorders within a tab, `fillActiveOrder()` writes the new sequence back
into *only the slots that tab occupies* in `master`, leaving players not visible in that
tab exactly where they were. Reordering two WRs in the WR tab therefore moves them in
Overall too, without disturbing any RB between them.

Player ids are derived, not stored: `slug(name) + "-" + team.toLowerCase()` (line ~415).
**Editing a player's name or team changes their id**, which orphans them from any saved
board. `reconcileMaster()` absorbs this — it keeps saved ids that still exist and appends
any new ones in default order — so saved boards degrade gracefully rather than breaking,
but the affected player silently reverts to his consensus slot.

Tier breaks (`tiers`) are per-tab and stored as *indices* into that tab's list, not as
player ids. They only exist on the four position tabs.

### Persistence

localStorage keys in use: `ff2026:board:v4` (the board), `ff2026:synccode` (sync code),
`ff2026:gl:<espnId>` (cached 2025 game logs), `ff2026:adp` (refreshed ADP). Only the
first is synced to Supabase.

`store = {master, drafted, tiers, updatedAt}`, JSON-serialized under `ff2026:board:v4`
in localStorage. `storeGet`/`storeSet` wrap this and are `async` specifically so remote
storage can slot in behind them; they also check for a `window.storage` host bridge.

The `:v4` suffix in `KEY` is a schema version. Bumping it silently abandons every saved
board — including boards already synced to Supabase, since the key is not part of the
sync payload. Prefer widening `reconcileMaster` over bumping the version.

`save()` is debounced 120ms locally and stamps `updatedAt`, which is what sync arbitrates on.

### Cross-device sync

A sync code (`xxxx-xxxx-xxxx`, 12 chars from an alphabet with no `0/1/i/l/o`) names one
row in Supabase. There are no accounts — whoever has the code has read/write on that
board. The code lives in localStorage under `ff2026:synccode`, separate from the board
itself, so disconnecting a device does not touch its rankings.

Flow: boot paints from localStorage first, then `pullRemote()` corrects from the server
and re-renders only if the remote copy is newer — the network never blocks first paint.
`save()` triggers a 600ms-debounced `pushRemote()`. A `visibilitychange` listener re-pulls
whenever the tab becomes visible, which is what makes picking up the phone "just work".
Conflicts are last-write-wins on `updatedAt`; there is no merge.

Sync degrades to a no-op if `SUPABASE_URL`/`SUPABASE_ANON_KEY` are blank — the board
still works, local-only.

### Player profile and ESPN data

Clicking a player opens a modal with three tabs: **Overview** (projections, unchanged),
**2025 Log** (week-by-week box scores), **2026 Sched** (opponent, home/away, date).

Two tables are baked into the file rather than fetched:

- `ESPN_ID` — 222 entries mapping our player id to an ESPN athlete id. Resolved from the
  32 team rosters, with six stragglers found via `search/v2` and each one verified against
  the athlete endpoint. Five of those six are free agents (`team:""`) absent from every
  roster; the sixth is Kenneth Gainwell, whom ESPN lists as "Kenny Gainwell".
- `SCHED` — all 32 teams' 2026 regular seasons. 18 semicolon-separated slots per team:
  `""` bye, `OPP:MM-DD` home, `@OPP:MM-DD` away, `nOPP:MM-DD` neutral site. Every derived
  bye week was cross-checked against the `bye` field already in `PLAYERS` — all 32 matched.

Schedules are baked so the tab works with no network, which matters on draft day. Game
logs are fetched live from `site.web.api.espn.com` because 222 players × 17 weeks is too
much to inline, then trimmed to the displayed columns and cached in localStorage under
`ff2026:gl:<espnId>`. 2025 is complete, so a cache hit is valid permanently.

ESPN's JSON endpoints send `Access-Control-Allow-Origin: *`, which is the only reason a
static page can call them at all. **Do not switch to scraping espn.com HTML** — those
pages send no CORS header and cannot be read from the browser.

Column sets differ by position and are keyed by ESPN's `names` array rather than by index,
since a QB's stat columns are not a WR's. Fantasy points are computed client-side in
`halfPPR()`, not taken from ESPN.

Rookies return a payload with no `seasonTypes` key at all; `trimGameLog` degrades to an
empty row list and the tab shows a "no games" note.

### ADP

`ADP` maps player id to ESPN's PPR average draft position, baked from
`lm-api-reads.fantasy.espn.com` with `view=kona_player_info` and an
`X-Fantasy-Filter` header. 220 of 222 are covered — Keenan Allen (unsigned) and
Brashard Smith fall outside ESPN's top 400 and genuinely have no ADP.

The **ADP** button opens a panel with a live refresh that overwrites the baked values
and stores them under `ff2026:adp` as `{asof, map}`. `adpOf()` prefers the live copy.
The refresh is deliberately manual because that view costs **~35KB per player** — about
12MB for 400 — and no combination of `filterStatsFor*` reduces it. That's fine on wifi
and a bad idea on draft day, hence the baked baseline.

`X-Fantasy-Filter` is a custom header, so it triggers a CORS preflight. ESPN's OPTIONS
response does allow it (`Access-Control-Allow-Headers: x-fantasy-filter`) and echoes the
requesting origin, so this works from the deployed site — but it is a preflighted request,
not a simple one.

#### ADP is the default board order

`defaultMaster` and `defaultTabOrder` both sort by `byAdp` — ADP ascending, `ovr` breaking
ties. This replaced the previous `ovr` / `posrk` ordering, so position tabs are ADP-ordered
too rather than following `posrk`.

Players ESPN doesn't rank fall back to their `ovr` value as a sort key. That works because
`ovr` runs 1–222 while ADP tops out near 171, so they sort below everyone — which matches
where their own `ovr` (210, 215) already placed them. It is a scale coincidence, not a
principle; if the ADP scale ever exceeds 222 this silently reshuffles them into the middle.

The ADP accessors (`ADP_KEY`, `adpLive`, `adpOf`) are declared **above** `defaultMaster` on
purpose — `defaultMaster()` runs inside `load()` and would hit a TDZ error on the `let` if
they stayed where the rest of the ADP code lives.

Changing the default does **not** touch an existing saved board: `reconcileMaster` keeps
saved ids in their saved order. Adopting a new baseline is always an explicit action —
"Reset board to ADP order" in the ADP panel, which replaces `master` wholesale, or the
per-tab Reset button. A successful refresh never reorders on its own; it shows how many
players *would* move (`orderDrift`) and makes you choose.

#### The delta is rank-to-rank, and the threshold is empirical

`adpDelta` compares `ARANK` (this pool ordered by ADP) to `MRANK` (your order). Do **not**
change it to compare `MRANK` against the raw ADP number: a real draft also spends picks on
kickers, defences and players this board doesn't carry, so raw ADP skews positive down the
board and every deep player looks like a bargain.

`ADP_EDGE` is 45 because this board disagrees with ESPN a lot — median gap is ~19 places.
Measured on the default order: a threshold of 10 colours 74% of the board, 20 colours 48%,
45 colours roughly 15%. Every player shows a plain delta; only outliers get colour. Lower
the threshold and the highlight stops carrying information.

#### Regenerating the baked tables

Neither table has a build script — they were generated with shell one-liners and pasted
in. If a player is added to `PLAYERS`, resolve their id from the roster endpoint:

```bash
curl -s "https://site.api.espn.com/apis/site/v2/sports/football/nfl/teams/cin/roster" \
| sed 's/{"id":"/\n@@/g' | grep '^@@' \
| sed -n 's/^@@\([0-9]\{4,8\}\)".*"fullName":"\([^"]*\)".*/\1|\2/p'
```

Then verify it resolves to the right person before trusting it:

```bash
curl -s "https://site.web.api.espn.com/apis/common/v3/sports/football/nfl/athletes/<id>" \
| grep -o '"displayName":"[^"]*"' | head -1
```

Schedules only need regenerating for a new season. Note that `shortName` uses `VS` (not
`@`) for neutral-site games — a naive `@`-only parse silently drops those games, which is
how a team ends up with 16 games instead of 17.

### Draft mode

`store.draft = {on, teams, slot, snake, offset}` — synced with the board, so settings and
pick position follow you between devices mid-draft.

**The pick counter is derived, not entered:** `pickNow() = drafted.size + 1 + offset`. The
crossed-off set is the single source of truth, which means the whole feature is only
correct if *every* pick gets marked, not just yours. `offset` exists so you can correct
drift without fake-drafting players to catch up.

`myPicks()` builds your turns from slot and league size; even rounds reverse when `snake`.
Verified against slots 1, 3 and 12 in a 12-team league (1/24/25/48, 3/22/27/46, 12/13/36/37).

#### Availability odds

`pLasts(pid, pick)` models a player's draft slot as normal around his ADP and returns
`1 - Φ((pick - adp) / σ)`. At `pick == adp` it returns exactly 50%, which is the quickest
way to check the maths still works.

**σ is measured, not invented.** `ADP_SD` holds each player's observed standard deviation
across 3,526 real mock drafts (fantasyfootballcalculator.com, PPR 12-team). This matters
more than it looks: at adp 40 and pick 55, σ=4 says 0% and σ=25 says 27%. A hand-picked
constant would be deciding the answer, not informing it.

Two things fell out of checking the real data, and both contradict the obvious guess:

- The spread is **not** a fixed fraction of ADP. The observed σ/adp ratio falls from ~0.24
  at the top of the board to ~0.11 deep. A flat 25% — the number I was about to hard-code —
  would have been 2–3× too wide across most of the board.
- The fallback for the 38 players FFC doesn't cover is therefore a least-squares line over
  the 184 it does: `σ = 1.411 + 0.0973·adp`, mean error 2.6 picks, little bias by band.

`draftCfg.vol` multiplies σ (0.7 / 1 / 1.4) so a league that drafts tighter or wilder than
the FFC average can be calibrated. It's a visible dial rather than a buried constant
precisely because it's the one genuinely unverifiable part of the model.

#### Monte Carlo (used whenever draft mode is on)

The closed form treats players independently and so never enforces one player leaving the
board per pick. Measured, that drifts hard: the marginals implied **185 players gone by
pick 180** when only 179 picks exist.

`mcRun()` samples `adp + σ·Z` for every undrafted player, sorts, and treats the ordering
as a draft — rank *r* goes at pick `now + r`. Coherence is then automatic (verified: 17.7
players + 0.3 phantoms = exactly the 18 picks between 28 and 46), and so is conditioning,
since only undrafted players enter the pool. **Picks are assigned by rank, not by ADP
magnitude**, so the ADP scale-calibration error that the closed form suffers from stops
mattering entirely — this is the main reason simulation wins here.

It is materially more pessimistic than the closed form, and correctly so: at pick 28 there
are 14 players with ADP between 28 and 46 competing for 18 slots, so a man at ADP 40 rarely
survives. Closed form said 26%, MC says 4%.

`MC_PHANTOM` (3) covers picks going to nobody on this board. It's small because adding
K/DST made the pool near-complete at 280 players for a ~180-pick draft. Raise it only if
you find real evidence of picks landing outside the pool.

**The jitter objection is handled by seeding**, not by avoiding simulation. `mcKey()` keys
the cache on the board state and `mulberry32` is seeded from it, so a given position always
produces identical numbers — no wobble between repaints. One run scores every player at
once, so cost is per pick (~1500 sims over ~280 players), not per card.

The closed form is still the fallback outside draft mode, where there's no pick position
to simulate from.

Still not done, and the genuine remaining use for sampling: **joint** questions ("will at
least one of these three last to pick 46"). The machinery is now in place — it needs the
per-sim survivor sets retained rather than collapsed into per-player counts.

**Conditioning is not optional.** `pLasts` divides by `pLastsRaw(pid, pickNow())`. Every
player on screen is provably undrafted *right now*, and the odds have to reflect that:
`P(slot > K | slot >= now)`. Without it, bubble players read **14–16 points too low**, and
a player sitting on your screen at your own pick showed **4%** instead of 100%. If you ever
refactor this, the one-line regression test is that `pick == pickNow` must return exactly 1.

Extreme fallers exhaust the model: once someone is many σ past his ADP the Gaussian says
his presence was impossible, and the conditional ratio becomes 0/0. Guarded by returning 0
below a `1e-6` base, i.e. "he goes next" — defensible, since fallers get scooped once
they're visibly value, but it is a guard, not a result.

`badgePick()` skips your current pick when you're on the clock. "Will he last until now"
is trivially yes, so the card badge advances to your following turn instead.

**Known, unfixed — scoring format.** The board is half-PPR; both ADP sources are PPR. FFC
publishes a `half-ppr` set that differs by a mean of 4.6 picks, with 25 players off by 10+
(worst: 20). That's roughly one σ of systematic error for mid-round players. It's left as
PPR because switching means giving up ESPN's live refresh and 222-player coverage for
FFC's 201 and a smaller 1,110-draft sample — a real trade, not an obvious win.

**Not an issue, though it looks like one:** FFC ignores its own `teams` parameter (10, 12
and 14 return identical payloads). This doesn't matter, because ADP counts *players taken
before him*, which is exactly what `pickNow()` counts. The two are directly comparable at
any league size; league size only moves where your own picks fall, which `myPicks()`
already handles.

**Caveat worth knowing:** ADP comes from ESPN, σ from FFC, and the two disagree by a mean
of 15.4 picks on the players they share. σ describes spread rather than location so it
transfers reasonably, but this is a seam. If ADP and σ ever need to agree exactly, switch
both to FFC — at the cost of live refresh, since FFC sends no CORS headers at all.

Badges hide above 95%: labelling those painted **169 of 222 cards**, which is wallpaper.
Long shots are never hidden — an available player already past his ADP is a faller, and
that's the most valuable read on the board.

#### Phones can't use the card's Draft button

The `max-width:480px` rule hides `.draftbtn` entirely, so before draft mode there was no
way to cross a player off on a phone — the device you draft from. The player modal carries
a full-width cross-off button (`data-draftp`) that works at any size. If you touch the card
layout, don't make that modal button the casualty.

`setDrafted()` is the single entry point for both controls: it updates the set, saves,
patches that one card in place, and repaints the bar and badges. Toggling deliberately
avoids a full `renderList()` — badges update in place via `repaintAvail()` so a fast draft
doesn't rebuild 222 cards per pick.

### Why the SQL looks the way it does

The publishable key is committed deliberately; static hosting has nowhere to hide a
secret. Security therefore lives entirely in the database:

- `boards` has RLS enabled with **no policies**, plus an explicit `revoke all`, so the
  anon role cannot touch the table at all. Verified: a direct `GET /rest/v1/boards`
  returns `permission denied`.
- All access goes through `board_get` / `board_put`, both `security definer`, both
  requiring the code. They can only ever return or write the single row you name, so
  the table cannot be enumerated.

If you ever grant the anon role direct table access "to simplify things", every board
in the table becomes world-readable to anyone who views source. Don't.

## Gotchas

- **The Supabase free tier pauses after 7 days of inactivity** and needs a manual click
  in the dashboard to resume. For a tool whose whole purpose is one day in August, this
  is the most likely real-world failure. Wake it before draft day.
- Browser cache masks deploys — hard-refresh (`Ctrl+Shift+R`) when a change seems missing.
- The GitHub Pages REST endpoint (`/repos/:owner/:repo/pages`) returns 404 to
  unauthenticated callers even when the site is live. Use the deployments endpoint or
  just fetch the URL to check status.
- `.srow` is already taken by the player-modal stat rows; sync UI classes are `syncbtns`,
  `smsg`, `codebox` to avoid colliding.
- The player modal sets `--pc` on the shared modal element. Any new modal must clear it
  (`modalEl.style.removeProperty("--pc")`) or it inherits the last player's position color.
