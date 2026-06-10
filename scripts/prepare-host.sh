#!/bin/sh
set -eu

if command -v modprobe >/dev/null 2>&1; then
  modprobe tun || true
fi

if [ ! -c /dev/net/tun ]; then
  mkdir -p /dev/net
  mknod /dev/net/tun c 10 200
  chmod 600 /dev/net/tun
fi

echo "prepared /dev/net/tun"
