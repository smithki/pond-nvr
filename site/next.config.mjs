// pond.camera, built and served by Vercel (site/README.md). Every page and pond.camera/api/search-model are made at
// build time: nothing runs on a server when someone visits. (JavaScript, not TypeScript: scripts/check-private.sh
// refuses .ts files, as MPEG transport streams are .ts too.)

/** @type {import("next").NextConfig} */
const config = {
  images: { unoptimized: true },
};

export default config;
