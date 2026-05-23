FROM debian:bookworm-slim

ARG ZIG_VERSION=0.15.2
ARG ZIG_TARGET=x86_64-linux

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl xz-utils libc6-dev \
    && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-${ZIG_TARGET}-${ZIG_VERSION}.tar.xz" -o /tmp/zig.tar.xz \
    && mkdir -p /opt/zig \
    && tar -xJf /tmp/zig.tar.xz -C /opt/zig --strip-components=1 \
    && rm /tmp/zig.tar.xz

ENV PATH="/opt/zig:${PATH}"

WORKDIR /app

COPY build.zig build.zig.zon ./
COPY src ./src
COPY zproxy.json ./zproxy.json

RUN zig build --release=fast

ENTRYPOINT ["/app/zig-out/bin/zproxy"]
