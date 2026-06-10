#!/bin/sh
set -eu

: "${ROLE:=gateway-controller}"

case "$ROLE" in
  gateway)
    exec /usr/local/bin/ovpn-gateway
    ;;
  controller)
    exec /usr/local/bin/ovpn-controller
    ;;
  gateway-controller|combined)
    exec /usr/local/bin/ovpn-combined
    ;;
  *)
    echo "error: unsupported ROLE: $ROLE" >&2
    echo "supported roles: gateway, controller, gateway-controller" >&2
    exit 64
    ;;
esac
