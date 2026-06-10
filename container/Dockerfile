FROM alpine:3.20

RUN apk add --no-cache \
    bind-tools \
    ca-certificates \
    curl \
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
COPY healthcheck.sh /usr/local/bin/ovpn-healthcheck
COPY openvpn-notify openvpn-auth-unlock /usr/local/sbin/

RUN chmod 755 \
    /usr/local/bin/ovpn-entrypoint \
    /usr/local/bin/ovpn-gateway \
    /usr/local/bin/ovpn-controller \
    /usr/local/bin/ovpn-combined \
    /usr/local/bin/ovpn-healthcheck \
    /usr/local/sbin/openvpn-notify \
    /usr/local/sbin/openvpn-auth-unlock \
    && ln -sf /usr/local/sbin/openvpn-notify /usr/local/sbin/openvpn-notify-down

ENTRYPOINT ["/sbin/tini", "-s", "--", "/usr/local/bin/ovpn-entrypoint"]
HEALTHCHECK --interval=30s --timeout=5s --retries=3 CMD /usr/local/bin/ovpn-healthcheck
