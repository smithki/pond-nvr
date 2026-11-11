"use client";

// The hero's camera wall: four tiles as cameras show them, each with the timestamp a camera prints on its picture
// (ticking, in the visitor's own time), what detection found in a box, and one camera kept private.
import { useEffect, useState } from "react";

const days = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
const pad = (n: number) => String(n).padStart(2, "0");

function stamp(d: Date) {
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${days[d.getDay()]} ${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`;
}

type Tile = {
  name: string;
  scene: string;
  box?: { label: string; color: string; left: string; top: string; width: string; height: string };
};

const tiles: Tile[] = [
  {
    name: "FRONT DOOR",
    scene: "linear-gradient(180deg, color-mix(in srgb, var(--scene-c) 70%, #000) 0 46%, var(--scene-a) 46% 100%)",
    box: { label: "Person 86%", color: "#6d8cff", left: "58%", top: "34%", width: "15%", height: "50%" },
  },
  {
    name: "DRIVEWAY",
    scene: "linear-gradient(180deg, var(--scene-c) 0 40%, color-mix(in srgb, var(--scene-d) 60%, #555) 40% 62%, var(--scene-b) 62% 100%)",
    box: { label: "Vehicle 91%", color: "#f0a24a", left: "12%", top: "46%", width: "34%", height: "22%" },
  },
  {
    name: "BACKYARD",
    scene: "linear-gradient(180deg, color-mix(in srgb, var(--scene-c) 80%, #000) 0 38%, var(--scene-b) 38% 100%)",
    box: { label: "Animal 78%", color: "#59c98a", left: "40%", top: "62%", width: "18%", height: "18%" },
  },
];

export function CameraWall() {
  // A fixed time until the page is running, so the server's page and the visitor's first frame agree.
  const [now, setNow] = useState("2026-11-09 Mon 21:14:07");
  useEffect(() => {
    const tick = () => setNow(stamp(new Date()));
    tick();
    const timer = setInterval(tick, 1000);
    return () => clearInterval(timer);
  }, []);

  return (
    <div className="wall" aria-label="Four cameras, live">
      {tiles.map((tile) => (
        <div className="tile" key={tile.name}>
          <div className="scene" style={{ background: tile.scene }} />
          {tile.box && (
            <div
              className="box"
              style={{ left: tile.box.left, top: tile.box.top, width: tile.box.width, height: tile.box.height, borderColor: tile.box.color }}
            >
              <span style={{ background: tile.box.color }}>{tile.box.label}</span>
            </div>
          )}
          <span className="osd">{now}</span>
          <span className="rec">REC</span>
          <span className="cam">{tile.name}</span>
        </div>
      ))}
      <div className="tile">
        <div className="scene" style={{ background: "linear-gradient(180deg, var(--scene-d) 0 55%, var(--scene-a) 55% 100%)" }} />
        <div className="private">
          Living Room
          <br />
          Private: not recorded
        </div>
      </div>
    </div>
  );
}
