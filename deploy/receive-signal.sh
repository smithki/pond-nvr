#!/bin/sh
# On the signaling server: a new pond-signal image, sent on standard input (gzipped `docker save`), loaded and started
# in place of the running one (the previous kept as deploy-signal:previous, to go back to). The only thing CI's deploy
# key may do here: its authorized_keys line names this script as its command (see README.md, "Deploying from CI").
set -eu
cd "$(dirname "$0")"
docker image inspect deploy-signal:latest >/dev/null 2>&1 && docker tag deploy-signal:latest deploy-signal:previous
gunzip | docker load
docker compose up -d --no-build --no-deps signal
docker ps --filter name=signal --format '{{.Names}} {{.Image}} {{.Status}}'
