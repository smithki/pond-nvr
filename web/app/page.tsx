// pond.camera: what Pond is, a night in its log (each line a link to what explains it), what it does, what it needs,
// and that it's open source. Every claim true of Pond today (the README's list of what works); the design in
// DESIGN.md.
import { DriveSize } from "@/components/DriveSize";
import { SearchExamples } from "@/components/SearchExamples";
import { Shot } from "@/components/Shot";

const repo = "https://github.com/smithki/pond-nvr";
const download = `${repo}/releases/latest`;
const version = "0.2.0";

/// A night, as Pond's log would tell it: time, where, what; each line goes to the section that explains it.
const night: { time: string; source: string; text: string; to: string; recording?: boolean }[] = [
  { time: "21:30", source: "pond", text: "recording 4 cameras to the NVR drive", to: "#records", recording: true },
  { time: "22:41", source: "driveway", text: "A grey car pulls into the driveway.", to: "#finds" },
  { time: "23:58", source: "front-door", text: "doorbell pressed: rang in the Home app", to: "#home-app" },
  { time: "02:16", source: "backyard", text: "A fox crosses the lawn and goes under the fence.", to: "#finds" },
  { time: "03:12", source: "garage", text: "not recorded 03:12–03:40: the camera didn’t answer", to: "#tells-you" },
  { time: "07:00", source: "pond", text: "daily summary: 3 cameras recorded all night; garage 28 min short", to: "#tells-you" },
];

function Mark() {
  return <img className="mark-icon" src="/mark.svg" alt="" width={30} height={30} />;
}

function Section({ id, title, children }: { id: string; title: string; children: React.ReactNode }) {
  return (
    <section id={id} className="section">
      <h2>
        <a href={`#${id}`}><span className="hash">#</span> {title}</a>
      </h2>
      {children}
    </section>
  );
}

export default function Home() {
  return (
    <div className="wrap">
      <header className="top">
        <a className="wordmark" href="#top">
          <Mark />
          Pond
        </a>
        <nav aria-label="Pond">
          <a href={`${repo}#readme`}>Docs</a>
          <a href={repo}>GitHub</a>
          <a className="button small" href={download}>Download</a>
        </nav>
      </header>

      <main id="top">
        <section className="hero">
          <h1>Every camera, recorded on your Mac.</h1>
          <p className="lead">
            Pond records your IP cameras around the clock to your own drive, tells you what happened in plain words,
            and puts each camera in Apple’s Home app. Free and open source. Your footage never leaves the house.
          </p>
          <div className="actions">
            <a className="button" href={download}>Download for Mac</a>
            <a className="button quiet" href={repo}>Source on GitHub</a>
          </div>
          <p className="fine">Version {version} · macOS 27 · Apple silicon · signed, notarized, updates itself</p>
        </section>

        <section className="night" aria-label="A night with Pond, as its log tells it">
          <div className="night-head">
            <span>pond.log</span>
            <span className="muted">a night at home</span>
          </div>
          <ol>
            {night.map((line) => (
              <li key={line.time}>
                <a href={line.to}>
                  <time>{line.time}</time>
                  <span className="source">{line.source}</span>
                  <span className="text">
                    {line.recording && <i className="rec" aria-label="recording" />}
                    {line.text}
                  </span>
                </a>
              </li>
            ))}
          </ol>
        </section>

        <Shot file="live.jpg" alt="Live: four cameras on the stage, the camera rail beside them"
              caption="Live, from Pond’s demo mode." />

        <Section id="records" title="Records">
          <p>
            Every camera, all the time, as one-minute MP4 files on a drive or NAS you choose, kept as long as you say.
            The Timeline puts a lane per camera on any day: drag to a moment, play from ½× to 16×, see what was private
            and what wasn’t recorded, and why.
          </p>
          <Shot file="timeline.jpg" alt="The Timeline: a lane per camera across a day, events marked on them"
                caption="The Timeline, from Pond’s demo mode." />
        </Section>

        <Section id="finds" title="Finds">
          <p>
            People, vehicles and animals, found in the video on your Mac, each event described in a sentence by Apple’s
            on-device model. Search a week of them the way you’d say it; the question never leaves your Mac either.
          </p>
          <SearchExamples />
          <Shot file="events.jpg" alt="Events: a grid of what the cameras saw, each with its picture and a sentence"
                caption="Events, from Pond’s demo mode." />
        </Section>

        <Section id="home-app" title="Home app">
          <p>
            Pond speaks HomeKit itself, no Homebridge: each camera you choose is in the Home app with live video and
            sound, doorbells ring, and with a home hub and iCloud+ it records to HomeKit Secure Video. Pond’s own sensor
            goes off in the Home app when recording stops, so you hear about it wherever you are.
          </p>
          <Shot file="homekit.jpg" alt="Settings › HomeKit: cameras in the Home app, how each is doing"
                caption="Settings › HomeKit, from Pond’s demo mode." width={1400} height={824} />
        </Section>

        <Section id="tells-you" title="Tells you">
          <p>
            A doctor for each camera says what’s wrong, since when, and what to try. When recording stops it says so at
            once, and after the fact says why (this Mac asleep, the drive full, the camera gone). Each morning, a
            summary: all well, or what wasn’t recorded.
          </p>
          <Shot file="doctor.jpg" alt="A camera’s Doctor page: its findings, the day’s gaps and charts"
                caption="A camera’s Doctor tab, from Pond’s demo mode." width={1400} height={1166} />
        </Section>

        <Section id="stays-home" title="Stays home">
          <dl className="facts">
            <dt>Recordings</dt>
            <dd>On your drive. There is no Pond cloud.</dd>
            <dt>Detection, descriptions, search</dt>
            <dd>On this Mac, by Core ML and Apple’s on-device models.</dd>
            <dt>Camera passwords</dt>
            <dd>In your Keychain. Never printed, never in a report.</dd>
            <dt>From away</dt>
            <dd>Another Mac paired with yours connects to it directly, encrypted end to end; Pond’s server only introduces them.</dd>
            <dt>This site</dt>
            <dd>No analytics, no cookies.</dd>
          </dl>
        </Section>

        <Section id="needs" title="Needs">
          <dl className="facts">
            <dt>Mac</dt>
            <dd>Apple silicon, macOS 27. It records in the background whenever you’re logged in.</dd>
            <dt>Cameras</dt>
            <dd>Any that send H.264 or H.265 over RTSP. Reolink best (doorbells, controls); others through ONVIF.</dd>
            <dt>Storage</dt>
            <dd>A drive or NAS for recordings. Unplugged, Pond stops writing and says so, rather than fill your Mac.</dd>
            <dt>HomeKit Secure Video</dt>
            <dd>A home hub (Apple TV or HomePod) and iCloud+.</dd>
          </dl>
          <h3>How big a drive?</h3>
          <DriveSize />
        </Section>

        <Section id="open-source" title="Open source">
          <p>
            Pond is free and open source: the app and recorder under the AGPL-3.0, its protocol and this site under the
            MIT License. Contributions are welcome, signed off (DCO), no CLA. The name, logo and icon are Pond’s own.
          </p>
          <div className="actions">
            <a className="button quiet" href={repo}>Read the source</a>
            <a className="button quiet" href={`${repo}/blob/main/docs/roadmap.md`}>What’s next</a>
          </div>
        </Section>
      </main>

      <footer>
        <span>Pond · pond.camera</span>
        <a href={download}>Download Pond {version}</a>
      </footer>
    </div>
  );
}
