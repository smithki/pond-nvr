"use client";

// How big a drive: continuous recording at about 32 GB per camera per day at 2560×1440 (the README's figure), for
// the cameras and days chosen, and the smallest common drive that holds it with room for event clips.
import { useState } from "react";

const gbPerCameraDay = 32;
const drivesTB = [1, 2, 4, 8, 12, 16, 20, 24];

export function DriveSize() {
  const [cameras, setCameras] = useState(4);
  const [days, setDays] = useState(14);
  const gb = cameras * days * gbPerCameraDay;
  const size = gb >= 1000 ? `${(gb / 1000).toFixed(1)} TB` : `${gb} GB`;
  // A tenth more, for event clips and the space kept free.
  const fit = drivesTB.find((tb) => tb >= (gb / 1000) * 1.1);

  return (
    <div className="disk">
      <div className="controls">
        <label htmlFor="cameras">
          <span className="row">
            <span>Cameras</span>
            <output htmlFor="cameras">{cameras}</output>
          </span>
          <input id="cameras" type="range" min={1} max={16} value={cameras} onChange={(e) => setCameras(Number(e.target.value))} />
        </label>
        <label htmlFor="days">
          <span className="row">
            <span>Days kept</span>
            <output htmlFor="days">{days}</output>
          </span>
          <input id="days" type="range" min={1} max={60} value={days} onChange={(e) => setDays(Number(e.target.value))} />
        </label>
      </div>
      <div className="result" aria-live="polite">
        <span className="label">Continuous recording needs about</span>
        <span className="big">{size}</span>
        <span className="muted">
          {fit ? `A ${fit} TB drive is enough, with room for event clips.` : "More than one large drive: a NAS, or fewer days."}
        </span>
      </div>
    </div>
  );
}
