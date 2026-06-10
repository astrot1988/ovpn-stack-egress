#!/bin/sh
set -eu

: "${DOCKER_HOST:=unix:///var/run/docker.sock}"
: "${HOST_PROC:=/host/proc}"
: "${GATEWAY_DNS:=openvpn}"
: "${GATEWAY_IP:=}"
: "${GATEWAY_IP_MODE:=local}"
: "${EGRESS_NETWORK_CIDRS:=}"
: "${TARGET_LABEL:=ovpn.egress}"
: "${SCAN_INTERVAL:=5}"
: "${GLOBAL_EXCLUDE_CIDRS:=}"
: "${SELF_CONTAINER_ID:=}"

export DOCKER_HOST

log() {
  printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >&2
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    log "error: required command missing: $1"
    exit 1
  }
}

inspect_json() {
  docker inspect "$1" 2>/dev/null | jq '.[0]'
}

container_label() {
  id="$1"
  key="$2"
  inspect_json "$id" | jq -r --arg key "$key" '.Config.Labels[$key] // empty'
}

container_pid() {
  inspect_json "$1" | jq -r '.State.Pid // 0'
}

container_network_ip() {
  id="$1"
  allowed_network_ids="$2"

  inspect_json "$id" | jq -r --arg ids "$allowed_network_ids" '
    ($ids | split("\n") | map(select(length > 0))) as $ids |
    .NetworkSettings.Networks
    | to_entries[]
    | select(.value.NetworkID as $network_id | $ids | index($network_id))
    | [.key, .value.IPAddress]
    | @tsv
  ' | head -n 1
}

self_container_id() {
  if [ -n "$SELF_CONTAINER_ID" ]; then
    printf '%s\n' "$SELF_CONTAINER_ID"
  else
    hostname
  fi
}

own_network_ids() {
  inspect_json "$(self_container_id)" |
    jq -r '.NetworkSettings.Networks | to_entries[] | .value.NetworkID' |
    awk 'NF'
}

resolve_gateway_ip() {
  if [ -n "$GATEWAY_IP" ]; then
    printf '%s\n' "$GATEWAY_IP"
    return 0
  fi

  if [ "$GATEWAY_IP_MODE" = "local" ]; then
    resolve_local_gateway_ip
    return 0
  fi

  ip_addr=""
  if command -v getent >/dev/null 2>&1; then
    ip_addr="$(getent hosts "$GATEWAY_DNS" 2>/dev/null | awk '$1 ~ /^[0-9.]+$/ { print $1; exit }')"
    if [ -n "$ip_addr" ]; then
      printf '%s\n' "$ip_addr"
      return 0
    fi
  fi

  dig +short "$GATEWAY_DNS" A 2>/dev/null | awk '$1 ~ /^[0-9.]+$/ { print $1; exit }'
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

resolve_local_gateway_ip() {
  cidrs="$EGRESS_NETWORK_CIDRS"
  if [ -z "$cidrs" ]; then
    ids="$(own_network_ids || true)"
    for id in $ids; do
      subnets="$(docker network inspect "$id" 2>/dev/null |
        jq -r '.[0].IPAM.Config[]?.Subnet // empty' |
        awk 'NF && $0 !~ /:/')"
      cidrs="${cidrs:+$cidrs }$subnets"
    done
  fi

  for cidr in $cidrs; do
    probe="$(cidr_probe_ip "$cidr")"
    ip_addr="$(ip route get "$probe" 2>/dev/null |
      sed -n 's/.* src \([0-9.]*\).*/\1/p' |
      head -n 1)"
    if [ -n "$ip_addr" ]; then
      printf '%s\n' "$ip_addr"
      return 0
    fi
  done

  hostname -i 2>/dev/null | awk '{ print $1; exit }'
}

nsenter_net() {
  pid="$1"
  shift
  nsenter --net="$HOST_PROC/$pid/ns/net" -- "$@"
}

target_iface_for_ip() {
  pid="$1"
  ip_addr="$2"
  nsenter_net "$pid" ip -o -4 addr show |
    awk -v ip_addr="$ip_addr" '
      {
        split($4, addr, "/")
        if (addr[1] == ip_addr) {
          sub(/@.*/, "", $2)
          print $2
          exit
        }
      }
    '
}

apply_excludes() {
  pid="$1"
  old_gw="$2"
  old_dev="$3"
  excludes="$4"

  [ -n "$old_gw" ] || return 0
  [ -n "$old_dev" ] || return 0

  for cidr in $excludes; do
    nsenter_net "$pid" ip route replace "$cidr" via "$old_gw" dev "$old_dev" || true
  done
}

route_container() {
  id="$1"
  gateway_ip="$2"
  allowed_network_ids="$3"

  label_value="$(container_label "$id" "$TARGET_LABEL")"
  case "$label_value" in
    true|1|yes|on) ;;
    *) return 0 ;;
  esac

  network_line="$(container_network_ip "$id" "$allowed_network_ids")"
  [ -n "$network_line" ] || {
    log "skip $id: not attached to openvpn network"
    return 0
  }
  network="$(printf '%s\n' "$network_line" | awk -F '\t' '{ print $1 }')"
  target_ip="$(printf '%s\n' "$network_line" | awk -F '\t' '{ print $2 }')"

  pid="$(container_pid "$id")"
  case "$pid" in
    ''|0|null) return 0 ;;
  esac

  netns="$HOST_PROC/$pid/ns/net"
  if [ ! -L "$netns" ] && [ ! -e "$netns" ]; then
    log "skip $id: netns not found for pid $pid"
    return 0
  fi

  nsenter_error="$(nsenter_net "$pid" true 2>&1)" || {
    log "skip $id: cannot enter netns for pid $pid: $nsenter_error"
    return 0
  }

  iface="$(target_iface_for_ip "$pid" "$target_ip")"
  [ -n "$iface" ] || {
    log "skip $id: cannot detect interface for $target_ip"
    return 0
  }

  current_default="$(nsenter_net "$pid" ip route show default 2>/dev/null | head -n 1 || true)"
  printf '%s\n' "$current_default" | grep -q "via $gateway_ip dev $iface" && return 0

  old_gw="$(printf '%s\n' "$current_default" | awk '{ for (i = 1; i <= NF; i++) if ($i == "via") { print $(i + 1); exit } }')"
  old_dev="$(printf '%s\n' "$current_default" | awk '{ for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i + 1); exit } }')"
  label_excludes="$(container_label "$id" ovpn.egress.exclude)"
  excludes="$(printf '%s %s\n' "$GLOBAL_EXCLUDE_CIDRS" "$label_excludes" | tr ',' ' ')"

  apply_excludes "$pid" "$old_gw" "$old_dev" "$excludes"
  nsenter_net "$pid" ip route replace default via "$gateway_ip" dev "$iface"
  log "routed $id on $network default via $gateway_ip dev $iface"
}

need_cmd date
need_cmd dig
need_cmd docker
need_cmd ip
need_cmd jq
need_cmd nsenter

[ -S /var/run/docker.sock ] || log "warning: /var/run/docker.sock is not a unix socket inside the controller"
[ -d "$HOST_PROC" ] || {
  log "error: host proc mount is missing: $HOST_PROC"
  exit 1
}

log "controller started: label=$TARGET_LABEL gateway_mode=$GATEWAY_IP_MODE gateway=$GATEWAY_DNS"

while :; do
  allowed_network_ids="$(own_network_ids || true)"
  if [ -z "$allowed_network_ids" ]; then
    log "openvpn container networks are not discoverable yet"
    sleep "$SCAN_INTERVAL"
    continue
  fi

  gateway_ip="$(resolve_gateway_ip || true)"
  if [ -z "$gateway_ip" ]; then
    log "gateway DNS is not resolvable yet: $GATEWAY_DNS"
    sleep "$SCAN_INTERVAL"
    continue
  fi

  docker ps -q --filter "label=$TARGET_LABEL" 2>/dev/null |
    while IFS= read -r id; do
      [ -n "$id" ] || continue
      route_container "$id" "$gateway_ip" "$allowed_network_ids" || log "failed to route $id"
    done

  sleep "$SCAN_INTERVAL"
done
