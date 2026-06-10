FROM alpine:3.20

RUN apk add --no-cache \
    bash \
    bind-tools \
    ca-certificates \
    curl \
    dnsmasq \
    docker-cli \
    expect \
    iproute2 \
    iptables \
    jq \
    openvpn \
    socat \
    tini \
    util-linux

COPY entrypoint.sh /usr/local/bin/ovpn-entrypoint
COPY gateway.sh /usr/local/bin/ovpn-gateway
COPY controller.sh /usr/local/bin/ovpn-controller
COPY combined.sh /usr/local/bin/ovpn-combined
COPY dns-proxy.sh /usr/local/bin/ovpn-dns-proxy
COPY healthcheck.sh /usr/local/bin/ovpn-healthcheck
COPY openvpn-notify openvpn-auth-unlock /usr/local/sbin/

RUN addgroup -S -g 53453 ovpn-dns \
    && adduser -S -D -H -u 53453 -G ovpn-dns ovpn-dns \
    && chmod 755 \
    /usr/local/bin/ovpn-entrypoint \
    /usr/local/bin/ovpn-gateway \
    /usr/local/bin/ovpn-controller \
    /usr/local/bin/ovpn-combined \
    /usr/local/bin/ovpn-dns-proxy \
    /usr/local/bin/ovpn-healthcheck \
    /usr/local/sbin/openvpn-notify \
    /usr/local/sbin/openvpn-auth-unlock \
    && ln -sf /usr/local/sbin/openvpn-notify /usr/local/sbin/openvpn-notify-down

ENTRYPOINT ["/sbin/tini", "-s", "--", "/usr/local/bin/ovpn-entrypoint"]
HEALTHCHECK --interval=10s --timeout=5s --retries=3 CMD /usr/local/bin/ovpn-healthcheck
