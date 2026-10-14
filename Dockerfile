# syntax=docker/dockerfile:1
# Anands Storage = SeaweedFS built from source at a pinned tag, with Anands branding on the Admin UI
# and an optional Authentik/OIDC login gate (oauth2-proxy) in front of the admin.
# The image keeps upstream's layout (/usr/bin/weed, /entrypoint.sh, /data), so it is a drop-in
# replacement for chrislusf/seaweedfs and existing /data volumes keep working untouched.
ARG SEAWEED_REF=4.13
ARG OAUTH2_PROXY_VERSION=v7.12.0

FROM quay.io/oauth2-proxy/oauth2-proxy:${OAUTH2_PROXY_VERSION} AS oauth

# ---- 1. Upstream source at a pinned tag ----
FROM alpine/git AS src
ARG SEAWEED_REF
RUN git clone --depth 1 --branch "${SEAWEED_REF}" https://github.com/seaweedfs/seaweedfs /src

# ---- 2. Apply branding, build weed ----
FROM golang:alpine AS build
ARG SEAWEED_REF
ENV GOTOOLCHAIN=auto
RUN apk add --no-cache nodejs git g++
COPY --from=src /src /src
COPY brand /brand
COPY scripts/apply-brand.mjs /scripts/apply-brand.mjs
RUN node /scripts/apply-brand.mjs /src /brand
WORKDIR /src/weed
RUN CGO_ENABLED=0 go install -ldflags "-extldflags -static -X github.com/seaweedfs/seaweedfs/weed/util/version.COMMIT=anands-${SEAWEED_REF}"

# ---- 3. Final image (mirrors upstream docker/Dockerfile.go_build) ----
FROM alpine AS final
ARG SEAWEED_REF
LABEL org.opencontainers.image.title="Anands Storage" \
      org.opencontainers.image.description="Anands Storage: branded SeaweedFS ${SEAWEED_REF} with optional OIDC SSO for the admin UI" \
      org.opencontainers.image.source="https://github.com/anandnms2/anands-storage"
COPY --from=build /go/bin/weed /usr/bin/
COPY --from=oauth /bin/oauth2-proxy /usr/bin/oauth2-proxy
RUN mkdir -p /etc/seaweedfs
COPY --from=src /src/docker/filer.toml /etc/seaweedfs/filer.toml
COPY --from=src /src/docker/entrypoint.sh /entrypoint.sh
COPY scripts/anands-entrypoint.sh /anands-entrypoint.sh
RUN apk add --no-cache fuse curl su-exec && \
    addgroup -g 1000 seaweed && \
    adduser -D -u 1000 -G seaweed seaweed && \
    mkdir -p /data/filerldb2 && \
    chown -R seaweed:seaweed /data /etc/seaweedfs && \
    chmod 755 /entrypoint.sh /anands-entrypoint.sh
EXPOSE 18080 8080 18888 8888 19333 9333 8333 7333
VOLUME /data
WORKDIR /data
ENTRYPOINT ["/anands-entrypoint.sh"]
