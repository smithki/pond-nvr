// A picture of the app: the screenshot when it's there, else a placeholder saying which picture goes here and the
// file to drop in (public/screenshots/<file>), so a missing one is plain to see and simple to fill.
import fs from "node:fs";
import path from "node:path";

export function Shot({ file, alt, caption, width = 1600, height = 1000 }: {
  file: string;
  alt: string;
  caption: string;
  width?: number;
  height?: number;
}) {
  const there = fs.existsSync(path.join(process.cwd(), "public", "screenshots", file));
  return (
    <figure className="shot">
      {there ? (
        <img src={`/screenshots/${file}`} alt={alt} width={width} height={height} />
      ) : (
        <div className="placeholder" style={{ aspectRatio: `${width} / ${height}` }} role="img" aria-label={`To come: ${alt}`}>
          <span>[ screenshot: {alt} ]</span>
          <span className="muted">public/screenshots/{file}</span>
        </div>
      )}
      <figcaption>{caption}</figcaption>
    </figure>
  );
}
