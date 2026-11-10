# pond.camera

Pond's landing page: a static [Next.js](https://nextjs.org) site. `next build` writes plain files to `out/`, to be
served from anywhere.

```sh
cd site
npm install
npm run dev      # http://localhost:3000, reloading as you edit
npm run build    # the site, in out/
npm run lint     # TypeScript's checks
```

- `app/page.tsx` is the page; `app/globals.css` its look (dark first, as the app is, and light for a light Mac).
- `components/` has the three parts that move: the camera wall's ticking timestamps, the example searches, and the
  drive-size sliders (`DriveSize`, from the README's 32 GB per camera per day at 2560×1440).
- The fonts (Bricolage Grotesque, Hanken Grotesk, JetBrains Mono) are fetched by `next/font` when the site is built
  and served with it: a visitor's browser never asks Google for them.

Every claim on the page should be true of Pond as it is: check it against the main README's list of what works,
and say so plainly when something isn't done yet.

## Screenshots

`public/screenshots/` holds pictures of the app from its demo mode only (made-up cameras, events and settings), and
each is named in `scripts/private-allowlist.txt`, which otherwise keeps pictures out of the repository. Never a
picture from a real home. To take new ones, the app's snapshot mode saves every view
([docs/development.md](../docs/development.md), *Pictures of the app*); crop and save them as JPEG at 1400 px
wide, for example:

```sh
sips -c 1000 1700 --cropOffset 104 500 settings-homekit.png --out homekit.png
sips -s format jpeg -s formatOptions 78 --resampleWidth 1400 homekit.png --out public/screenshots/homekit.jpg
```
