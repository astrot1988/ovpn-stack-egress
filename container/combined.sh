#!/bin/sh
set -eu

gateway_pid=""
controller_pid=""

stop_children() {
  [ -z "$controller_pid" ] || kill -TERM "$controller_pid" 2>/dev/null || true
  [ -z "$gateway_pid" ] || kill -TERM "$gateway_pid" 2>/dev/null || true
  wait 2>/dev/null || true
}

trap stop_children INT TERM

/usr/local/bin/ovpn-gateway &
gateway_pid="$!"

/usr/local/bin/ovpn-controller &
controller_pid="$!"

while :; do
  if ! kill -0 "$gateway_pid" 2>/dev/null; then
    wait "$gateway_pid" || exit $?
    exit 1
  fi

  if ! kill -0 "$controller_pid" 2>/dev/null; then
    wait "$controller_pid" || exit $?
    exit 1
  fi

  sleep 2
done
