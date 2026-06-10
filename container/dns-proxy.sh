#!/bin/sh
set -eu

: "${OVPN_DNS_LISTEN:=127.0.0.53}"
: "${OVPN_DNS_FALLBACK:=127.0.0.11}"
: "${OVPN_DNS_PROXY_USER:=ovpn-dns}"
: "${OVPN_DNS_PROXY_GROUP:=ovpn-dns}"

server="${1:?dns server is required}"
domains="${2:?dns domains are required}"

set -- dnsmasq \
  --no-daemon \
  --keep-in-foreground \
  --no-hosts \
  --no-resolv \
  --no-poll \
  --bind-interfaces \
  --listen-address="$OVPN_DNS_LISTEN" \
  --port=53 \
  --user="$OVPN_DNS_PROXY_USER" \
  --group="$OVPN_DNS_PROXY_GROUP" \
  --server="$OVPN_DNS_FALLBACK"

for domain in $(printf '%s\n' "$domains" | tr ',;' '  '); do
  domain="${domain#.}"
  domain="${domain%.}"
  case "$domain" in
    \*.*) domain="${domain#*.}" ;;
  esac
  [ -n "$domain" ] || continue
  set -- "$@" "--server=/$domain/$server"
done

exec "$@"
