# syntax=docker/dockerfile:1.7

# Nothing here is pinned; every version is resolved when the image is built.
#   TELEPORT_REF  "latest" = Teleport's newest vX.Y.Z source tag (the base that
#                 teleport.patch is applied to). Set a tag to build an older one.
#   TSH_VERSION   empty = the newest tsh published on cdn.teleport.dev in the
#                 same major as TELEPORT_REF (binaries often ship before their
#                 source tag does).
#   Go            whatever Teleport's go.mod at TELEPORT_REF declares, enforced
#                 with GOTOOLCHAIN. A newer Go is NOT safe here: a dependency
#                 (charlievieth/strcase) panics at startup under Go 1.27.
ARG TELEPORT_REF=latest
ARG TSH_VERSION=

FROM golang:1 AS build
ARG TELEPORT_REF
ARG TSH_VERSION
RUN apt-get update \
    && apt-get install --no-install-recommends -y git \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /src
RUN ref="${TELEPORT_REF}" \
    && if [ "$ref" = latest ]; then \
         ref=$(git ls-remote --tags --refs https://github.com/gravitational/teleport.git 'v*' \
           | sed 's#.*/##' | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1); \
       fi \
    && echo "Teleport source ${ref}" \
    && git clone --filter=blob:none https://github.com/gravitational/teleport.git . \
    && git checkout "${ref}" \
    && test "$(git describe --tags --exact-match HEAD)" = "${ref}" \
    && echo "${ref#v}" > /tmp/teleport-version
COPY teleport.patch /tmp/teleport.patch
RUN git apply /tmp/teleport.patch
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    tc=$(sed -n 's/^toolchain //p' go.mod) \
    && export GOTOOLCHAIN="${tc:-go$(sed -n 's/^go //p' go.mod)}" \
    && echo "Go toolchain ${GOTOOLCHAIN}" \
    && CGO_ENABLED=0 go build \
      -tags kustomize_disable_go_plugin_support \
      -trimpath -ldflags="-w -s" \
      -o /out/teleport-slack \
      ./integrations/access/slack/cmd/teleport-slack
RUN v="${TSH_VERSION}" \
    && if [ -z "$v" ]; then \
         v=$(cat /tmp/teleport-version); \
         major=${v%%.*}; rest=${v#*.}; minor=${rest%%.*}; patch=${rest#*.}; \
         has() { curl -fsI -o /dev/null "https://cdn.teleport.dev/teleport-v$1-linux-amd64-bin.tar.gz"; }; \
         while :; do \
           if has "$major.$minor.$((patch+1))"; then patch=$((patch+1)); \
           elif has "$major.$minor.$((patch+2))"; then patch=$((patch+2)); \
           elif has "$major.$((minor+1)).0"; then minor=$((minor+1)); patch=0; \
           else break; fi; \
         done; \
         v="$major.$minor.$patch"; \
       fi \
    && echo "tsh ${v}" \
    && curl -fsSL \
      "https://cdn.teleport.dev/teleport-v${v}-linux-amd64-bin.tar.gz" \
      -o /tmp/teleport.tar.gz \
    && tar -xzf /tmp/teleport.tar.gz -C /tmp \
    && install -m 0755 /tmp/teleport/tsh /out/tsh

FROM debian:stable-slim
RUN apt-get update \
    && apt-get install --no-install-recommends -y ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --system --gid 10001 teleport-slack \
    && useradd --system --uid 10001 --gid teleport-slack \
       --home-dir /var/lib/teleport-slack teleport-slack \
    && install -d -o teleport-slack -g teleport-slack -m 0700 \
       /var/lib/teleport-slack/beams
COPY --from=build /out/teleport-slack /usr/local/bin/teleport-slack
COPY --from=build /out/tsh /usr/local/bin/tsh
USER 10001:10001
VOLUME ["/var/lib/teleport-slack/beams"]
ENTRYPOINT ["/usr/local/bin/teleport-slack"]
CMD ["start", "--config=/etc/teleport-slack/config.toml"]
