# pond.camera

Pond's website, and the manifest Pond learns of search's model versions from: a [Next.js](https://nextjs.org) site,
built and served by Vercel from `main` (this folder is the project's root directory). Every page and
`/api/search-model` are made when it's built, so nothing runs on a server when someone visits; there are no
analytics.

```sh
cd web
npm install
npm run dev      # http://localhost:3000, reloading as you edit
npm run build    # the site, as Vercel builds it (npm start serves it)
npm run lint     # TypeScript's checks
```

- [DESIGN.md](DESIGN.md) is how it looks and why: type, colour, pictures, rules.
- `app/page.tsx` is the page (its words, the night in Pond's log at its top); `app/globals.css` its look (dark,
  its colours at the top).
- `components/`: the example searches, the drive-size sliders (`DriveSize`, from the README's 32 GB per camera per
  day at 2560×1440), and `Shot`, a picture of the app or, until its file is in `public/screenshots/`, a placeholder
  naming it.
- `data/search-models.json` is the search model manifest, served at `/api/search-model` by
  `app/api/search-model/route.js`. Its entries come from the search model workflow's pull requests, signed: don't
  edit one by hand, since Pond refuses an entry whose signature doesn't verify ([docs/search.md](../docs/search.md),
  *Published versions*).
- The fonts (Bricolage Grotesque for the wordmark, Fira Code for the rest) are fetched by `next/font` when the site is built
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
