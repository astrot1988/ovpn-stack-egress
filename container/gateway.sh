#!/bin/sh
set -eu

: "${OPENVPN_CONFIG:=/config/client.ovpn}"
: "${OPENVPN_AUTH_USER_PASS:=}"
: "${OPENVPN_EXTRA_ARGS:=}"
: "${OPENVPN_MANAGEMENT_SOCKET:=/run/ovpn-egress/openvpn.sock}"
: "${OPENVPN_KEY_LABEL:=Private Key}"
: "${OPENVPN_NOTIFY_DIR:=/run/ovpn-egress}"
: "${NOTIFY_URL:=}"
: "${VPN_INTERFACE:=tun0}"
: "${EGRESS_NETWORK_CIDRS:=}"
: "${RUNTIME_DIR:=/run/ovpn-egress}"
: "${SELF_CONTAINER_ID:=}"

die() {
  echo "error: $*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command missing: $1"
}

iptables_ensure() {
  table="$1"
  chain="$2"
  shift 2

  if [ "$table" = "filter" ]; then
    iptables -w -C "$chain" "$@" 2>/dev/null || iptables -w -A "$chain" "$@"
  else
    iptables -w -t "$table" -C "$chain" "$@" 2>/dev/null || iptables -w -t "$table" -A "$chain" "$@"
  fi
}

cidr_probe_ip() {
  cidr="$1"
  base="${cidr%/*}"
  old_ifs="$IFS"
  IFS=.
  # shellcheck disable=SC2086
  set -- $base
  IFS="$old_ifs"

  [ "$#" -eq 4 ] || {
    printf '%s\n' "$base"
    return 0
  }

  octet="$4"
  case "$octet" in
    ''|*[!0-9]*) octet=1 ;;
  esac
  if [ "$octet" -lt 254 ]; then
    octet=$((octet + 1))
  fi
  printf '%s.%s.%s.%s\n' "$1" "$2" "$3" "$octet"
}

route_iface_for_cidr() {
  cidr="$1"
  probe="$(cidr_probe_ip "$cidr")"
  ip route get "$probe" 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -n 1
}

self_container_id() {
  if [ -n "$SELF_CONTAINER_ID" ]; then
    printf '%s\n' "$SELF_CONTAINER_ID"
  else
    hostname
  fi
}

own_network_ids() {
  docker inspect "$(self_container_id)" 2>/dev/null |
    jq -r '.[0].NetworkSettings.Networks | to_entries[] | .value.NetworkID' |
    awk 'NF'
}

own_network_subnets() {
  ids="$1"

  for id in $ids; do
    docker network inspect "$id" 2>/dev/null |
      jq -r '.[0].IPAM.Config[]?.Subnet // empty' |
      awk 'NF && $0 !~ /:/'
  done | awk '!seen[$0]++'
}

egress_network_cidrs() {
  if [ -n "$EGRESS_NETWORK_CIDRS" ]; then
    printf '%s\n' "$EGRESS_NETWORK_CIDRS"
    return 0
  fi

  ids="$(own_network_ids || true)"
  [ -n "$ids" ] || return 0
  own_network_subnets "$ids"
}

prepare_openvpn_config() {
  mkdir -p "$RUNTIME_DIR"
  runtime_config="$RUNTIME_DIR/client.ovpn"

  if [ -n "$OPENVPN_AUTH_USER_PASS" ]; then
    [ -r "$OPENVPN_AUTH_USER_PASS" ] || die "OPENVPN_AUTH_USER_PASS is not readable: $OPENVPN_AUTH_USER_PASS"
    awk -v auth="$OPENVPN_AUTH_USER_PASS" '
      /^[[:space:]]*askpass([[:space:]]|$)/ { next }
      /^[[:space:]]*auth-user-pass([[:space:]]|$)/ {
        print "auth-user-pass " auth
        found = 1
        next
      }
      { print }
      END {
        if (!found) {
          print "auth-user-pass " auth
        }
      }
    ' "$OPENVPN_CONFIG" >"$runtime_config"
  else
    awk '
      /^[[:space:]]*askpass([[:space:]]|$)/ { next }
      /^[[:space:]]*auth-user-pass[[:space:]]+/ { print "auth-user-pass"; next }
      { print }
    ' "$OPENVPN_CONFIG" >"$runtime_config"
  fi

  printf '%s\n' "$runtime_config"
}

notify_credentials_required() {
  [ -n "$NOTIFY_URL" ] || return 0
  [ -z "$OPENVPN_AUTH_USER_PASS" ] || return 0
  awk '
    /^[[:space:]]*(#|;|$)/ { next }
    /^[[:space:]]*auth-user-pass[[:space:]]*$/ { found = 1 }
    END { exit found ? 0 : 1 }
  ' "$1" || return 0
  /usr/local/sbin/openvpn-notify credentials-required
}

configure_forwarding() {
  cidrs="$(egress_network_cidrs)"
  [ -n "$cidrs" ] || die "failed to detect egress network CIDRs"

  sysctl -w net.ipv4.ip_forward=1 >/dev/null || die "failed to enable net.ipv4.ip_forward"

  for cidr in $cidrs; do
    iface="$(route_iface_for_cidr "$cidr")"
    [ -n "$iface" ] || die "failed to detect interface for egress CIDR: $cidr"

    iptables_ensure nat POSTROUTING -s "$cidr" -o "$VPN_INTERFACE" -j MASQUERADE
    iptables_ensure filter FORWARD -i "$iface" -o "$VPN_INTERFACE" -s "$cidr" -j ACCEPT
    iptables_ensure filter FORWARD -i "$VPN_INTERFACE" -o "$iface" -d "$cidr" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

    # Kill switch for traffic received from the egress overlay: if it is not
    # going out through the VPN interface, reject it inside this namespace.
    iptables_ensure filter FORWARD -i "$iface" -s "$cidr" ! -o "$VPN_INTERFACE" -j REJECT

    echo "configured egress forwarding: $cidr via $iface -> $VPN_INTERFACE"
  done
}

need_cmd ip
need_cmd iptables
need_cmd docker
need_cmd jq
need_cmd openvpn
need_cmd socat
need_cmd sysctl

[ -c /dev/net/tun ] || die "/dev/net/tun is missing; mount it from the host"
[ -r "$OPENVPN_CONFIG" ] || die "OpenVPN config is not readable: $OPENVPN_CONFIG"

mkdir -p "$(dirname "$OPENVPN_MANAGEMENT_SOCKET")" "$OPENVPN_NOTIFY_DIR"
rm -f "$OPENVPN_MANAGEMENT_SOCKET"
configure_forwarding
runtime_config="$(prepare_openvpn_config)"
notify_credentials_required "$runtime_config"

# Intentionally use word splitting for OPENVPN_EXTRA_ARGS so operators can pass
# normal OpenVPN flags from the stack environment.
# shellcheck disable=SC2086
exec openvpn \
  --ignore-unknown-option dns dns-updown \
  --config "$runtime_config" \
  --dns-updown disable \
  --script-security 2 \
  --down /usr/local/sbin/openvpn-notify-down \
  --management "$OPENVPN_MANAGEMENT_SOCKET" unix \
  --management-query-passwords \
  $OPENVPN_EXTRA_ARGS
