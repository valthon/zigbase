# Example app restyles — distinct themes per example

**Date:** 2026-06-18
**Status:** Approved (detailed creative brief from user)

## Goal

Give each of the three example apps its own strong, distinct visual identity so the
complexity ladder (blog → golfsim → plugins) also reads as a *stylistic* range, and
regenerate the marketing-site screenshots to match.

| Example | Theme | Mood |
| --- | --- | --- |
| `examples/blog` | Retro 90s GeoCities/MySpace | Loud, nostalgic, over-the-top |
| `examples/golfsim` | Golf ethos: pastels + precision geometry | Calm, premium, country-club |
| `examples/plugins` | Cyberpunk futuristic AI | High-tech "AI console" |

## Current state

All three frontends are Astro 5 + React 19 islands and currently share an **identical**
23-line dark `global.css` (`--bg #101216`, `--accent #f7a41d`, `.card`, `.muted`,
`.error`, plus input/button rules). The restyle replaces each example's `global.css`
with a full thematic system and updates that example's `Layout.astro`/`index.astro`
chrome and any inline component styles. **No backend/logic/Zig changes.**

- blog: `Layout.astro` (header/nav), `pages/{index,post,write}.astro`, `components/{PostList,PostView,Editor}.tsx`
- golfsim: `Layout.astro`, `pages/{index,bookings}.astro`, `components/{Auth,ListingsBrowser,MyBookings}.tsx` (ListingsBrowser has inline styles)
- plugins: `pages/index.astro` (inline layout, no Layout.astro), `components/Browser.tsx`; `frontend/dist` is **embedded into the binary** at build time

## Hard constraint: preserve screenshot selectors

`scripts/screenshots.sh` drives each running example with **fixed Playwright selectors**.
The restyle MUST keep these structural hooks (or the script must be updated in lockstep —
preferred path is to keep the hooks):

- All: `.card` class on cards; login card `input[placeholder="email"]`,
  `input[placeholder^="password"]`, `button` with text "Log in"
- blog: `article.card h2`; `/write` editor `input[placeholder="Title"]` + `textarea`
- golfsim: `input[type="datetime-local"]`; `/bookings` `article.card strong`
- plugins: `section.card ul li`

Theming is via CSS/markup decoration around these hooks, not by removing them.

## Theme specs

### blog — 90s MySpace
Tiled/starfield CSS background, garish gradient header bar, Comic Sans + Times font
stacks, neon/visited link colors, beveled "table" cards (ridge/outset borders),
a marquee-style scrolling banner, a faux hit counter, CSS-drawn "under construction"
energy, web-ring footer badges. All decoration is CSS-only — no external image assets.

### golfsim — golf pastels + precision
Palette: sky blue, cream/off-white, soft sand; **grass-green CTA buttons** (~`#2f8f4e`).
Thin hairline rules + subtle grid background, scorecard motifs, monospace tabular
numerals for prices/yardage, geometric sans body with a restrained serif for headings.

### plugins — cyberpunk AI
Near-black base, neon cyan/magenta accents, monospace UI, glowing card borders,
scanline + grid overlay, terminal-style data browser, subtle gradient glow. CSS-only.

## Screenshots & docs sync

After each frontend builds clean, regenerate the 5 example shots
(`example-blog-home`, `example-blog-write`, `example-golfsim-listings`,
`example-golfsim-bookings`, `example-plugins-browser`) via
`scripts/screenshots.sh examples`, then `cd site && npm run build`. The 9 `admin-*`
shots are the admin SPA (not restyled) and stay untouched. Scan example `.mdx`/README
prose for stale visual descriptions and update any that describe the old dark look.

## Execution

One worktree, one branch/PR. The three restyles touch disjoint directories → run as
parallel subagents pinned to the worktree, then screenshots + site build serially.
