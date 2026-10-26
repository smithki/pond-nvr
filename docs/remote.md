# Remote access

Reaching a Pond from outside its network: another Mac first (another Pond, the start of "sites"), then the iPhone app. Peer to peer: the two ends connect directly wherever they can, and nothing in between can read what they say. It's still being built: pairing, finding a path between two Ponds, and an encrypted session over it carrying live video and the remote API (cameras, events, pictures, clips, search, controls) work, from the command line; the apps come next. See the roadmap's *Away from home*.

## The pieces

- **Pond, on each Mac.** With `remote.enabled`, its service stays connected to a signaling service, answers pairing, and answers connections from the devices and Ponds paired with it.
- **A signaling service of your own**: `pond-signal`, in `deploy/`, on any server Docker runs on (a small VPS is plenty). It passes sealed messages between paired devices, and answers STUN (UDP 3478 and 3479), so a Pond can learn the address the world sees it at without asking a third party.
- **Optionally, a relay of your own** (coturn, `deploy/`'s `relay` profile), for when no direct path works; or **a mesh** (Tailscale or Headscale, the `mesh` profile), for connecting only over its tunnel.

## Setting it up

1. Deploy the signaling service: `deploy/README.md`. Point a DNS name at the server, and open TCP 443 and UDP 3478–3479.
2. On each Mac, in the settings file: `"remote": { "enabled": true, "signaling": "wss://signal.example.com" }` ([configuration.md](configuration.md#remote-access) has the rest), and restart the service (`pond service restart`).
3. Pair: on the Pond to be reached, `pond remote pair` shows a code (and a QR code), good once for ten minutes; on the other, `pond remote join CODE`. `pond remote devices` lists who's paired on each.
4. Try it: `pond remote connect DEVICE` (by its name or id) finds a path and says how it went. `pond remote watch DEVICE CAMERA` watches one of its cameras for ten seconds (`--seconds N`; `--main` for the main stream; `--kbps N [--size WxH]` to have it re-encoded smaller, as for a weak link), keeps what came as an MP4 (`--out PATH`), and says how it went: pictures, frame rate, bitrate, loss, how soon the first came. `pond remote cameras DEVICE` lists its cameras; `pond remote events DEVICE` its last day's events (`--hours N`, `--camera CAMERA`), each with its id; `pond remote search DEVICE QUESTION` asks it a question; `pond remote picture DEVICE EVENT` and `pond remote clip DEVICE EVENT` fetch an event's picture or clip (`--out PATH`).

## Trying it across two networks

What only a real test shows: two Macs on different networks finding each other. You need a small Linux server with a public address and Docker (any VPS does), and a second Mac you can put on another network (a phone's hotspot is the easiest).

1. **The signaling service, on the server.** For a first try, plain `ws://` on a port of its own is enough (messages are sealed end to end, so the server learns nothing either way; for keeping it, use `deploy/`'s compose file and a domain, for `wss://`). Build the image on your Mac and copy it over, so the server needs nothing but Docker:

   ```sh
   docker buildx build --platform linux/amd64 -f deploy/Dockerfile.signal -t pond-signal --load .
   docker save pond-signal | ssh SERVER docker load
   ssh SERVER docker run -d --name pond-signal --restart unless-stopped -p 8080:8080 -p 3478-3479:3478-3479/udp pond-signal
   ```

   (`linux/arm64` for an ARM server.) Open TCP 8080 and UDP 3478–3479 in the server's firewall.

2. **The Pond to be reached** (the one with the cameras): in its settings file, `"remote": { "enabled": true, "signaling": "ws://SERVER:8080" }`; then `pond service restart`, and `pond remote pair` for a code.

3. **The second Mac**: build Pond (`make app`), `pond init`, point its storage at any folder (`pond storage recordings ~/PondTest`), add the same `remote` section, and start its service (`pond service install`; with remote access on it runs without cameras of its own). Then `pond remote join CODE`, and `pond remote devices` on each to see they're paired.

4. **Put the second Mac on the other network** (the hotspot), and on it:

   - `pond remote connect NAME` (the first Mac's name, as `pond remote devices` lists it): how it connected (straight, through the routers' public addresses, IPv4 or IPv6, and the round trip), or why it couldn't and what would fix it.
   - `pond remote watch NAME CAMERA --seconds 15`: the camera's stream over the encrypted session, kept as an MP4 (the path is printed); how many pictures came, the frame rate, bitrate and loss.
   - `--kbps 300` on the same: re-encoded smaller, as a phone on a weak signal would ask for it.
   - `pond remote events NAME`, then `pond remote clip NAME EVENT` with one of their ids: the clip comes over in pieces, and the size and where it's kept are printed. `pond remote search NAME "people today"` too.
   - Switch networks during a watch (the hotspot to Wi-Fi): the path is found again, and the video goes on.

5. **Afterwards**: `ssh SERVER docker rm -f pond-signal`, and `remote.enabled` back to `false` on each Mac (or leave it on, with the server kept).

If it can't connect, the diagnosis says what to try; `remote.relay` with `deploy/`'s relay profile is the way through two strict routers (see below).

## How a connection is made

The one connecting sends the Pond an offer, sealed to it through the signaling service: a password and username for this attempt, and the addresses it can be reached at (its candidates). The Pond answers likewise. Each side's candidates:

- **Its own addresses**: its Wi-Fi and Ethernet IPv4 addresses, and its *temporary* IPv6 addresses (they change every day or so, and don't come from the hardware). Never its stable IPv6 address, link-local ones, VPN tunnels or virtual machines' networks. `remote.shareLocalAddresses: false` leaves them all out.
- **Its public address**, as the signaling host's STUN sees it: the router's.
- **A relayed address**, if there's a relay.

Each side then checks pairs of its own and the other's candidates, best first (own addresses, then public ones, then the relay), with STUN messages signed with the other's password: anyone else's go unanswered. A check that reaches a side from an address it didn't know about teaches it a new candidate, which it checks straight back; that's how two home routers, each letting in only replies to its own traffic, are got through. The Pond being reached chooses the best pair that worked, and both use it from then on, checking it every few seconds to keep the routers' paths open. (This is RFC 8445's Interactive Connectivity Establishment, cut down to what two Ponds need: `PathFinder` in `src/Sources/Traversal`.)

When either Mac's network changes (another Wi-Fi network, Wi-Fi to a phone's hotspot), they find a path again, the old one carrying on until there's a new one.

## The session

Once there's a path, everything between the two goes over it, encrypted with keys made for that session alone: each side put a one-time key in its sealed offer or answer, and the session's keys come from the two (X25519, then HKDF). They're forgotten when it ends, so what was said can't be read later, even with a Pond's own keys.

- **The control channel**: requests and their replies (ChaCha20-Poly1305), each delivered once and in order whatever the path loses or reorders.
- **Live video**: a camera's stream as the Home app gets it (`LiveSession`): the camera's own H.264 as it arrives, or re-encoded to a size and bitrate the viewer asks for, which its reports then steer; SRTP, in packets small enough for any path.
- **The API**, on the control channel (`RemoteAPI` in `src/Sources/Remote`): its cameras (names, kinds, privacy); events since a time or by their ids, with what was seen, their sentences, and whether they have a picture and a clip; an event's picture or clip, in pieces of 256 KB; and the cameras' controls (moving them, their settings, privacy) and search, as the app asks for them at home. Pairing, the settings and talking back aren't offered, and files are read only as an event's own picture or clip, from the events folder.

The checks, the channel and the video share one UDP port, told apart by each packet's first byte.

## When it can't connect

`pond remote connect` (and the service's log) says why, and what would fix it, from what each side learned about its network:

- **A "symmetric" router on one side or both** (common on cellular and office networks): it shows the world a new port for every destination, which direct paths can't get through when the other side's router is strict too. Pond tells by asking STUN at two ports.
- **STUN didn't answer**: UDP 3478 is blocked, on the server's firewall or the network's.
- **Both have IPv6, but it didn't work**: a router's IPv6 firewall is blocking incoming UDP.

The fixes, in the order to try them:

1. **Turn on IPv6** at the router (both ends, ideally). IPv6 needs no address translation, so most of the above goes away.
2. **Forward a UDP port** to the Pond being reached: set `remote.port` (45000, say) and forward that port on its router.
3. **Use a mesh**: Tailscale (or your own Headscale) on both, and `remote.mesh: true`. Connections then go only over the mesh's tunnel, which it makes work through almost anything.
4. **Run a relay of your own**: `docker compose --profile relay up -d` in `deploy/`, then `remote.relay` on each Mac and its secret with `pond remote relay-secret`. Everything then goes through it when nothing better works; it's chosen last.

## What each party sees

| Who | Sees | Never sees |
|---|---|---|
| The signaling service | That two mailboxes exchanged sealed messages, and their sizes | What's in them: addresses, credentials, anything about the cameras |
| The relay (if used) | The two ends' public addresses, and the packets it passes on | Anything else (and, once the encrypted session comes, what's in the packets) |
| The other end (paired) | The addresses offered to it | This Mac's stable IPv6 address, or its own addresses at all with `shareLocalAddresses: false` |
| Anyone else | Nothing: their offers go unopened, their checks unanswered | |
