# pond.camera's design

What the site looks like and why, so it can be kept up (and changed) without a designer.

## The idea

A code editor's clarity, stripped to the basics: dark, high contrast, set in a monospaced font, and nothing on the
page that doesn't say something about Pond. Its story is told the way Pond itself tells it: **a night in Pond's
log**, a few lines near the top, each a link to the part of the page that explains it. Then plain sections, each
headed like a heading in a text file (`# Records`), saying in a few sentences what Pond does and showing it.

Straight to the point: what it is, download it, what it does, what it needs, that it's open source.

## Type

| Use | Font | Where it's set |
|---|---|---|
| The wordmark ("Pond") | **Bricolage Grotesque**, bold | `app/layout.tsx` (`--font-mark`) |
| Everything else: headings, text, the log | **Fira Code** | `app/layout.tsx` (`--font-code`) |

Both are free and open, downloaded when the site's built and served with it (a visitor's browser never asks Google
for them).

## Colour

From the app icon (`macos/app/AppIcon.icon`): its deep navy-teal, its teal ripple, its red recording dot. All in
`app/globals.css`, at the top:

| Token | Colour | For |
|---|---|---|
| `--bg` | `#0b1419` | the page |
| `--panel` | `#101d24` | the log, pictures, the spec sheet |
| `--line` | `#22333b` | rules and borders |
| `--fg` | `#eef4f5` | text (high contrast) |
| `--muted` | `#8ea2a9` | secondary text, the log's times |
| `--teal` | `#65d9d1` | the brand: links, headings' `#`, what's highlighted |
| `--red` | `#ff453a` | recording, only |

Dark only, as the app is by default. One accent at a time: teal for anything you can act on, red only where
something is recording.

## Pictures

Screenshots from the app's demo mode only (made-up cameras; never anyone's home), in `public/screenshots/`, named
in `scripts/private-allowlist.txt` (which otherwise keeps pictures out of the repository). Where one isn't made
yet, the page shows a placeholder saying which picture goes there and its file name: drop the file in with that
name and it shows. To make them, the app's snapshot mode (`docs/development.md`, *Pictures of the app*), cropped and
saved as JPEG about 1600 px wide:

```sh
open -n -W --env POND_SNAPSHOTS=/tmp/shots --env POND_SNAPSHOTS_ONLY=live "dist/demo/Pond NVR.app" --args --demo home
sips -s format jpeg -s formatOptions 80 --resampleWidth 1600 /tmp/shots/live.png --out public/screenshots/live.jpg
```

## Rules

- Every claim true of Pond as it is (the main README's list); what isn't done yet says so.
- No analytics, no cookies, nothing loaded from elsewhere.
- No decoration for its own sake: no gradients, glows or animation that don't say something about Pond.
