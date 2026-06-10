#!/bin/sh
set -eu

: "${OPENVPN_MANAGEMENT_SOCKET:=/run/ovpn-egress/openvpn.sock}"
: "${VPN_INTERFACE:=tun0}"

gateway_healthy() {
  ip link show "$VPN_INTERFACE" >/dev/null 2>&1 && return 0

  [ -S "$OPENVPN_MANAGEMENT_SOCKET" ] &&
    pidof openvpn >/dev/null 2>&1
}

controller_healthy() {
  docker version --format '{{.Server.Version}}' >/dev/null 2>&1
}

case "${ROLE:-gateway-controller}" in
  gateway)
    gateway_healthy
    ;;
  controller)
    controller_healthy
    ;;
  gateway-controller|combined)
    gateway_healthy
    ;;
  *)
    exit 1
    ;;
esac
