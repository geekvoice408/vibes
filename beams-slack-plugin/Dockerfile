# syntax=docker/dockerfile:1.7

ARG TELEPORT_REF=v18.11.1
ARG TSH_VERSION=18.11.1
ARG GO_IMAGE=golang:1.25.14-bookworm

FROM ${GO_IMAGE} AS build
ARG TELEPORT_REF
ARG TSH_VERSION
RUN apt-get update \
    && apt-get install --no-install-recommends -y git \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /src
RUN git clone --filter=blob:none https://github.com/gravitational/teleport.git . \
    && git checkout "${TELEPORT_REF}" \
    && test "$(git describe --tags --exact-match HEAD)" = "${TELEPORT_REF}"
COPY teleport.patch /tmp/teleport.patch
RUN git apply /tmp/teleport.patch
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 go build \
      -tags kustomize_disable_go_plugin_support \
      -trimpath -ldflags="-w -s" \
      -o /out/teleport-slack \
      ./integrations/access/slack/cmd/teleport-slack
RUN curl -fsSL \
      "https://cdn.teleport.dev/teleport-v${TSH_VERSION}-linux-amd64-bin.tar.gz" \
      -o /tmp/teleport.tar.gz \
    && tar -xzf /tmp/teleport.tar.gz -C /tmp \
    && install -m 0755 /tmp/teleport/tsh /out/tsh

FROM debian:bookworm-slim
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
