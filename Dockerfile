# syntax=docker/dockerfile:1

ARG BIRD_VERSION=3.0.1
ARG YQ_VERSION=4.45.1

# ---- builder: compile BIRD from source ----
FROM debian:trixie-slim AS builder

ARG BIRD_VERSION

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        make curl build-essential bison m4 flex \
        libncurses5-dev libreadline-dev libssh-dev pkg-config \
    && rm -rf /var/lib/apt/lists/*

RUN BIRD_TAR="bird-${BIRD_VERSION}.tar.gz" && \
    BIRD_URL="https://bird.network.cz/download/${BIRD_TAR}" && \
    curl -fsSL -O "${BIRD_URL}" && \
    ( curl -fsSL -O "${BIRD_URL}.sha256" 2>/dev/null \
        && sha256sum -c "${BIRD_TAR}.sha256" \
        || echo "WARN: no checksum file published, continuing" ) && \
    tar -zxf "${BIRD_TAR}" -C /tmp && \
    mv "/tmp/bird-${BIRD_VERSION}" /bird

RUN cd /bird \
    && ./configure \
        --prefix=/usr \
        --sysconfdir=/etc/bird \
        --runstatedir=/var/run/bird \
        --disable-doc \
        --disable-debug \
    && make -j"$(nproc)" \
    && chmod +x /bird/bird /bird/birdc

# ---- runtime ----
FROM debian:trixie-slim

ARG BIRD_VERSION
ARG YQ_VERSION
ENV BIRD_VERSION=${BIRD_VERSION}

LABEL org.opencontainers.image.source="https://github.com/mrkhachaturov/bird" \
      org.opencontainers.image.description="BIRD + URL/ASN/MaxMind list fetcher, config-driven via sources.yaml" \
      org.opencontainers.image.licenses="MIT"

COPY --from=builder /bird/bird /bird/birdc /usr/sbin/

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        libssh-4 libreadline8 libncursesw6 \
        iproute2 bash tini \
        curl unzip gawk python3 whois bgpq4 gettext-base \
        libcap2-bin \
    && groupadd -r bird && useradd -r -g bird -d /var/run/bird -s /usr/sbin/nologin bird \
    && mkdir -p /etc/bird /etc/blacklist /var/run/bird /var/cache/blacklist \
    && chown -R bird:bird /etc/bird /var/run/bird /var/cache/blacklist \
    && chmod 770 /var/run/bird \
    && ln -sf /usr/sbin/birdc /usr/bin/birdc \
    && ln -sf /usr/sbin/bird /usr/bin/bird \
    && setcap cap_net_raw,cap_net_admin+ep /usr/sbin/bird \
    && apt-get remove -y --purge libcap2-bin \
    && apt-get autoremove -y --purge \
    && rm -rf /var/lib/apt/lists/* \
    && ARCH=$(dpkg --print-architecture) \
    && curl -fsSL -o /usr/local/bin/yq \
        "https://github.com/mikefarah/yq/releases/download/v${YQ_VERSION}/yq_linux_${ARCH}" \
    && chmod +x /usr/local/bin/yq

COPY scripts/ /usr/local/bin/

RUN chmod +x \
    /usr/local/bin/entrypoint.sh \
    /usr/local/bin/fetch-lists.sh \
    /usr/local/bin/maxmind-country.py \
    /usr/local/bin/refresh \
    /usr/local/bin/refresh-maxmind \
    /usr/local/bin/status \
    /usr/local/bin/webhook.py

HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
    CMD birdc -s /var/run/bird/bird.ctl show status >/dev/null 2>&1 || exit 1

EXPOSE 179/tcp 9090/tcp

STOPSIGNAL SIGTERM

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
