# Build environment for SwarmPanel (server + wasm). wasm-bindgen-cli must match web/Cargo.toml.
FROM rust:1-bookworm
RUN rustup target add wasm32-unknown-unknown \
 && cargo install wasm-bindgen-cli --version 0.2.100 --locked \
 && rm -rf /usr/local/cargo/registry
