# The data tools in one image: the pipelines that build a database, the Rust programs they run,
# sa-builder from unipept-index, umgap, and the loader that puts the proteins into OpenSearch. One
# version for all of them, so the tables a build writes fit the mapping the loader uses.
# .github/workflows/image.yml builds it; a version tag publishes it to ghcr.io/unipept/unipept-database.
#
# A run mounts the host's database directory at the same path, for example:
#   docker run --rm --network host -v /mnt/data:/mnt/data ghcr.io/unipept/unipept-database:<version> \
#     opensearch/load.sh --opensearch-url http://localhost:9200 ...

# The programs of this workspace, with stable Rust as CI builds them; rust-toolchain.toml's nightly
# is only for rustfmt.
FROM rust:1-bookworm AS workspace
ENV RUSTUP_TOOLCHAIN=stable
WORKDIR /src
COPY Cargo.toml Cargo.lock ./
COPY crates crates
RUN cargo build --release --locked

# sa-builder, at the unipept-index commit this image records. Its libsais64-rs builds libsais with
# cmake and generates the bindings with bindgen, which needs libclang.
FROM rust:1-bookworm AS sa-builder
ARG UNIPEPT_INDEX_COMMIT=07ab4f2f834cf7f85d696a2d8fa210b95d611f99
RUN apt-get update -qq \
 && apt-get install -y -qq --no-install-recommends clang cmake libclang-dev \
 && rm -rf /var/lib/apt/lists/*
RUN git clone --quiet https://github.com/unipept/unipept-index.git /src \
 && git -C /src checkout --quiet "$UNIPEPT_INDEX_COMMIT"
WORKDIR /src
RUN cargo build --release --locked -p sa-builder

# umgap, at the version CI's umgap suite installs.
FROM rust:1-bookworm AS umgap
ARG UMGAP_VERSION=1.2.0
RUN cargo install --locked --version "$UMGAP_VERSION" umgap

FROM debian:bookworm-slim
RUN apt-get update -qq \
 && apt-get install -y -qq --no-install-recommends \
      bash ca-certificates coreutils curl gawk libxml2-utils lz4 pigz procps pv python3 \
      python3-requests unzip uuid-runtime zip \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /opt/unipept-database
COPY pipelines pipelines
COPY opensearch opensearch
# Where the pipelines look for the workspace's programs (RUST_BIN_DIR in pipelines/lib/common.sh).
COPY --from=workspace \
     /src/target/release/function-calculator /src/target/release/lca-calculator \
     /src/target/release/taxdmp-parser /src/target/release/uniprot-parser \
     /src/target/release/uniprot-parser-tryptic \
     target/release/
COPY --from=sa-builder /src/target/release/sa-builder /usr/local/bin/
COPY --from=umgap /usr/local/cargo/bin/umgap /usr/local/bin/
