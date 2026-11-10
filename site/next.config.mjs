// A static site: `next build` writes plain files to out/, to be served from anywhere (pond.camera). (JavaScript, not
// TypeScript: scripts/check-private.sh refuses .ts files, as MPEG transport streams are .ts too.)

/** @type {import("next").NextConfig} */
const config = {
  output: "export",
  images: { unoptimized: true },
};

export default config;
