// pond.camera: what Pond is, what it does at home, and what it needs. Every claim here is true of Pond today (the
// README's list of what works); what isn't done yet says so.
import { CameraWall } from "@/components/CameraWall";
import { DriveSize } from "@/components/DriveSize";
import { SearchExamples } from "@/components/SearchExamples";

const repo = "https://github.com/smithki/pond-nvr";

function PondMark() {
  return (
    <svg viewBox="0 0 32 32" aria-hidden="true">
      <circle cx="16" cy="16" r="14" fill="none" stroke="currentColor" strokeWidth="2.4" />
      <circle cx="16" cy="16" r="8" fill="none" stroke="var(--accent)" strokeWidth="2.4" />
      <circle cx="16" cy="16" r="2.6" fill="var(--accent)" />
    </svg>
  );
}

export default function Home() {
  return (
    <div className="wrap">
      <header className="top">
        <a className="mark" href="#top" aria-label="Pond">
          <PondMark />
          Pond
        </a>
        <nav aria-label="Sections">
          <a href="#views">The app</a>
          <a href="#homekit">HomeKit</a>
          <a href="#home">Stays home</a>
          <a href="#needs">What it needs</a>
        </nav>
      </header>

      <main id="top">
        <section className="hero">
          <div className="hero-copy">
            <span className="status">
              <i />
              In development · open source
            </span>
            <h1>Every camera, recorded on your Mac.</h1>
            <p className="lead">
              Pond records your IP cameras around the clock to a drive you choose, tells you what happened in plain words,
              and puts each camera in Apple’s Home app. No bridge to set up, nothing to subscribe to for recording, and
              your footage never leaves the house.
            </p>
            <div className="actions">
              <a className="button primary" href={repo}>
                Follow on GitHub
              </a>
              <a className="button" href={`${repo}/blob/main/docs/roadmap.md`}>
                See what’s next
              </a>
            </div>
          </div>
          <CameraWall />
        </section>

        <section className="band" id="views">
          <div className="section-head">
            <span className="label">The app</span>
            <h2>Three views, each for one job.</h2>
            <p className="muted">
              What’s happening now, what happened when, and what happened that’s worth knowing. One click apart in the
              toolbar.
            </p>
          </div>
          <div className="three">
            <article className="view">
              <span className="key">LIVE</span>
              <h3>Every camera at once, with sound</h3>
              <p className="muted">
                A rail of every camera beside a stage as large as the window allows. Double-click one to watch it alone,
                and move it, talk through its speaker or switch it to night.
              </p>
            </article>
            <article className="view">
              <span className="key">TIMELINE</span>
              <h3>Any day, a lane per camera</h3>
              <p className="muted">
                Drag to any moment, play from ½× to 16×, zoom from a whole day to 15 minutes, and scroll back across
                midnight. Press L to jump to now.
              </p>
            </article>
            <article className="view">
              <span className="key">EVENTS</span>
              <h3>What the cameras saw</h3>
              <p className="muted">
                People, vehicles and animals found in the video, each described in a sentence, new ones marked until
                you’ve seen them.
              </p>
            </article>
          </div>
        </section>

        <section className="band" id="search">
          <div className="section-head">
            <span className="label">Search</span>
            <h2>Ask for it the way you’d say it.</h2>
            <p className="muted">
              Every event gets a picture and a sentence describing it, made by Apple’s on-device models. So you can
              search your week in plain words, and the question never leaves your Mac either.
            </p>
          </div>
          <SearchExamples />
        </section>

        <section className="band" id="homekit">
          <div className="split">
            <div className="copy">
              <span className="label">HomeKit</span>
              <h2>In the Home app, without Homebridge.</h2>
              <p className="muted">
                Pond speaks HomeKit itself. Each camera you choose shows up in the Home app with live video, sound and
                snapshots, and doorbells ring like doorbells. With a home hub and iCloud+, cameras record to HomeKit
                Secure Video too.
              </p>
              <ul className="facts">
                <li>One page shows every camera in the Home app, how it’s doing and what it sends.</li>
                <li>Recording can differ when you’re home and away. Pond says “not recording right now”, not “off”.</li>
                <li>Several people can watch at once.</li>
              </ul>
            </div>
            <figure className="shot">
              <img
                src="/screenshots/homekit.jpg"
                alt="Pond’s HomeKit settings: four cameras in the Home app, one live, one waiting to be added, two more ready to add."
                width={1400}
                height={824}
              />
              <figcaption>Settings › HomeKit, from Pond’s demo mode.</figcaption>
            </figure>
          </div>
        </section>

        <section className="band" id="doctor">
          <div className="split flip">
            <div className="copy">
              <span className="label">Camera health</span>
              <h2>A doctor for each camera.</h2>
              <p className="muted">
                Cameras drop off Wi-Fi, stall, refuse a changed password. Pond notices, says what’s wrong and since when,
                and suggests what to try. The menu bar tells you if recording stops, and the toolbar shows what needs a
                look.
              </p>
              <ul className="facts">
                <li>The last 24 hours as charts: frame rate and interruptions.</li>
                <li>Run Check… logs in, watches a few seconds of video and reads the camera’s controls.</li>
                <li>Copy Report gives it all as text for a bug report, without the address or password.</li>
              </ul>
            </div>
            <figure className="shot">
              <img
                src="/screenshots/doctor.jpg"
                alt="A camera’s Doctor page: no problems in the last hour, HomeKit Secure Video’s last clip, the last 24 hours as charts."
                width={1400}
                height={1166}
              />
              <figcaption>A camera’s Doctor tab, from Pond’s demo mode.</figcaption>
            </figure>
          </div>
        </section>

        <section className="band" id="home">
          <div className="section-head">
            <span className="label">Stays home</span>
            <h2>Your footage never leaves the house.</h2>
            <p className="muted">There’s no Pond cloud to upload to. What leaves your Mac is only what you choose to send.</p>
          </div>
          <div className="ledger">
            <div>
              <h3>Recordings</h3>
              <p className="muted">One-minute MP4 files on a drive or NAS you choose, kept as long as you say.</p>
            </div>
            <div>
              <h3>Detection and descriptions</h3>
              <p className="muted">Core ML and Apple’s on-device models, on this Mac alone.</p>
            </div>
            <div>
              <h3>Camera passwords</h3>
              <p className="muted">In your Keychain. Never printed, never in a report.</p>
            </div>
            <div>
              <h3>From away</h3>
              <p className="muted">
                Another Mac paired with yours connects to it directly, encrypted end to end. Pond’s service only
                introduces them and can read nothing they send.
              </p>
            </div>
          </div>
        </section>

        <section className="band" id="disk">
          <div className="section-head">
            <span className="label">Disk</span>
            <h2>How big a drive?</h2>
            <p className="muted">
              At 2560×1440, continuous recording takes about 32 GB per camera per day. Pond tells you if the days you want
              to keep won’t fit, and the oldest goes first.
            </p>
          </div>
          <DriveSize />
        </section>

        <section className="band" id="needs">
          <div className="section-head">
            <span className="label">What it needs</span>
            <h2>The spec sheet.</h2>
          </div>
          <div className="specs-scroll">
            <table className="specs">
              <tbody>
                <tr>
                  <th scope="row">Mac</th>
                  <td>Apple silicon, macOS 27. Pond records in the background whenever you’re logged in, with its window closed.</td>
                </tr>
                <tr>
                  <th scope="row">Cameras</th>
                  <td>
                    Any that send H.264 or H.265 over RTSP. Reolink is supported best (models, doorbell presses, controls);
                    others through ONVIF.
                  </td>
                </tr>
                <tr>
                  <th scope="row">Storage</th>
                  <td>
                    An external drive or NAS share for continuous recording. Pond stops writing, and says so, if the drive is
                    unplugged, rather than filling your Mac.
                  </td>
                </tr>
                <tr>
                  <th scope="row">HomeKit Secure Video</th>
                  <td>A home hub (Apple TV or HomePod) and an iCloud+ plan.</td>
                </tr>
                <tr>
                  <th scope="row">Availability</th>
                  <td>Open source (AGPL-3.0). Not yet released: build it from source today, with a signed release on the roadmap.</td>
                </tr>
              </tbody>
            </table>
          </div>
        </section>
      </main>

      <footer>
        <span>Pond · pond.camera</span>
        <span>Open source under the AGPL-3.0 · Made on a Mac, for a Mac</span>
      </footer>
    </div>
  );
}
