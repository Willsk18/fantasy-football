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
