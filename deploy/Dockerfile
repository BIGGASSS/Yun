# Build context: server/ (docker build -f deploy/Dockerfile server)
FROM rust:1.98.1-bookworm AS build
WORKDIR /build
COPY Cargo.toml Cargo.lock ./
COPY src ./src
COPY migrations ./migrations
RUN cargo build --release --locked --bin yun-server

FROM debian:bookworm-slim AS runtime
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --gid 10001 yun \
    && useradd --uid 10001 --gid 10001 --no-create-home --shell /usr/sbin/nologin yun \
    && install -d -m 0700 -o yun -g yun /var/lib/yun
COPY --from=build /build/target/release/yun-server /usr/local/bin/yun-server
USER 10001:10001
ENV YUN_DATA_DIR=/var/lib/yun
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
  CMD curl --fail --silent http://127.0.0.1:8080/health > /dev/null || exit 1
ENTRYPOINT ["/usr/local/bin/yun-server"]
CMD ["serve", "--bind", "0.0.0.0:8080", "--behind-tls-proxy"]
