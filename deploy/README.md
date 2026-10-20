# Remote access: the services

Pond reaches your Mac from outside peer to peer: your devices connect to it directly, video encrypted end to end. To find each other they need a little help, which you can run yourself, on any Linux host with Docker that's reachable from the internet (a small VPS is plenty). Pond itself stays on your Mac.

| Service | What it does | What it sees |
|---|---|---|
| `signal` (always) | Passes envelopes between your Mac and your paired devices, so they can agree how to connect; answers STUN, so each learns the address the internet sees it at. | Which mailboxes (hashes of keys) talk, when, and how much. Never what's in an envelope: each is sealed to its recipient's key and signed by its sender. Keeps nothing. |
| `caddy` (always) | HTTPS for the signaling service (`wss://your-domain`), with a free certificate. | The same. |
| `coturn` (profile `relay`) | A relay, for when your Mac and a device can't reach each other directly (both behind strict NAT or carrier-grade NAT, and no IPv6). Pond doesn't use one unless you set it. | Both ends' addresses, and the encrypted video passing through. |
| `headscale` (profile `mesh`) | A private WireGuard mesh, for Pond's "only over my mesh" mode: no public address ever exchanged. | Your mesh's devices. |

## Starting

```sh
cd deploy
POND_SIGNAL_DOMAIN=signal.example.com docker compose up -d
```

Point a DNS name at the server first, and open TCP 80 and 443 (HTTPS) and UDP 3478 (STUN). Then in Pond: Settings › Remote Access › Signaling server: `wss://signal.example.com`.

With a relay: set `static-auth-secret` in `turnserver.conf`, open UDP 3480 and 49160–49200, start with `--profile relay`, and give Pond the relay's address and the same secret. With the mesh: set `server_url` in `headscale/config.yaml`, open TCP 8443 and UDP 3479, start with `--profile mesh`, and join your Mac and devices with Tailscale's apps pointed at it.

## Without any of this

If your Mac and your devices are on a mesh already (Tailscale, Headscale or another WireGuard network), Pond can connect over it with nothing else: its signaling still needs a service, but nothing else does.
