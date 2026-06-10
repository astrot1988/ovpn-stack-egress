#!/bin/sh
set -eu

: "${IMAGE:=ovpn-egress:dev}"

cd "$(dirname "$0")/.."
docker build -t "$IMAGE" container
