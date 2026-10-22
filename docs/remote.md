# Remote access

Reaching a Pond from outside its network: another Mac first (another Pond, the start of "sites"), then the iPhone app. Peer to peer: the two ends connect directly wherever they can, and nothing in between can read what they say. It's still being built: pairing and finding a path between two Ponds work (`pond remote connect`); the encrypted session that carries video and control comes next. See the roadmap's *Away from home*.

## The pieces

- **Pond, on each Mac.** With `remote.enabled`, its service stays connected to a signaling service, answers pairing, and answers connections from the devices and Ponds paired with it.
- **A signaling service of your own**: `pond-signal`, in `deploy/`, on any server Docker runs on (a small VPS is plenty). It passes sealed messages between paired devices, and answers STUN (UDP 3478 and 3479), so a Pond can learn the address the world sees it at without asking a third party.
- **Optionally, a relay of your own** (coturn, `deploy/`'s `relay` profile), for when no direct path works; or **a mesh** (Tailscale or Headscale, the `mesh` profile), for connecting only over its tunnel.

## Setting it up

1. Deploy the signaling service: `deploy/README.md`. Point a DNS name at the server, and open TCP 443 and UDP 3478–3479.
2. On each Mac, in the settings file: `"remote": { "enabled": true, "signaling": "wss://signal.example.com" }` ([configuration.md](configuration.md#remote-access) has the rest), and restart the service (`pond service restart`).
3. Pair: on the Pond to be reached, `pond remote pair` shows a code (and a QR code), good once for ten minutes; on the other, `pond remote join CODE`. `pond remote devices` lists who's paired on each.
4. Try it: `pond remote connect DEVICE` (by its name or id) finds a path and says how it went.

## How a connection is made

The one connecting sends the Pond an offer, sealed to it through the signaling service: a password and username for this attempt, and the addresses it can be reached at (its candidates). The Pond answers likewise. Each side's candidates:

- **Its own addresses**: its Wi-Fi and Ethernet IPv4 addresses, and its *temporary* IPv6 addresses (they change every day or so, and don't come from the hardware). Never its stable IPv6 address, link-local ones, VPN tunnels or virtual machines' networks. `remote.shareLocalAddresses: false` leaves them all out.
- **Its public address**, as the signaling host's STUN sees it: the router's.
- **A relayed address**, if there's a relay.

Each side then checks pairs of its own and the other's candidates, best first (own addresses, then public ones, then the relay), with STUN messages signed with the other's password: anyone else's go unanswered. A check that reaches a side from an address it didn't know about teaches it a new candidate, which it checks straight back; that's how two home routers, each letting in only replies to its own traffic, are got through. The Pond being reached chooses the best pair that worked, and both use it from then on, checking it every few seconds to keep the routers' paths open. (This is RFC 8445's Interactive Connectivity Establishment, cut down to what two Ponds need: `PathFinder` in `src/Sources/Traversal`.)

When either Mac's network changes (another Wi-Fi network, Wi-Fi to a phone's hotspot), they find a path again, the old one carrying on until there's a new one.

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
