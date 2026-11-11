// pond.camera/api/search-model: which versions of search's picture model Pond may download, and where
// (data/search-models.json). Made when the site is built, a static file: nothing runs when Pond asks for it, and
// nothing about who asks is kept beyond the host's own request logs. Pond trusts an entry only for its signature.
// (JavaScript, not TypeScript: scripts/check-private.sh refuses .ts files.)
import manifest from "@/data/search-models.json";

export const dynamic = "force-static";

export function GET() {
  return Response.json(manifest, { headers: { "Cache-Control": "public, max-age=3600" } });
}
