#!/bin/sh
set -eu

case "${ROLE:-gateway-controller}" in
  gateway)
    ip link show "${VPN_INTERFACE:-tun0}" >/dev/null 2>&1
    ;;
  controller)
    docker version --format '{{.Server.Version}}' >/dev/null 2>&1
    ;;
  gateway-controller|combined)
    ip link show "${VPN_INTERFACE:-tun0}" >/dev/null 2>&1
    docker version --format '{{.Server.Version}}' >/dev/null 2>&1
    ;;
  *)
    exit 1
    ;;
esac
