# Nyxframe (Rust): one static binary on the same Alpine 3.20 base (and so the
# same ffmpeg + VAAPI drivers) the Lua build ran on.
FROM rust:1-alpine3.20 AS build
RUN apk add --no-cache musl-dev build-base
WORKDIR /src
COPY Cargo.toml Cargo.lock ./
COPY server server
RUN --mount=type=cache,target=/usr/local/cargo/registry --mount=type=cache,target=/src/target \
    cargo build --release -p nyxframe && cp target/release/nyxframe /nyxframe

FROM alpine:3.20
RUN apk add --no-cache ffmpeg mesa-va-gallium libva-utils zip ca-certificates tzdata
COPY --from=build /nyxframe /usr/local/bin/nyxframe
EXPOSE 8788
CMD ["nyxframe"]
