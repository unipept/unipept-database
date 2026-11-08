# The data tools in one image: the pipelines that build a database, the Rust programs they run,
# sa-builder from unipept-index, umgap, and the loader that puts the proteins into OpenSearch. One
# version for all of them, so the tables a build writes fit the mapping the loader uses.
# .github/workflows/image.yml builds it; a version tag publishes it to ghcr.io/unipept/unipept-database.
#
# A run mounts the host's database directory at the same path, as the user who owns it, for example:
#   docker run --rm --user "$(id -u):$(id -g)" --network host -v /mnt/data:/mnt/data \
#     ghcr.io/unipept/unipept-database:<version> \
#     opensearch/load.sh --opensearch-url http://localhost:9200 ...

# The programs of this workspace, with stable Rust as CI builds them: rust-toolchain.toml, whose
# nightly is for rustfmt, is not copied. Every program the build makes goes to /out.
FROM rust:1-trixie AS workspace
WORKDIR /src
COPY Cargo.toml Cargo.lock ./
COPY crates crates
RUN cargo build --release --locked \
 && mkdir /out && find target/release -maxdepth 1 -type f -executable -exec cp {} /out/ \;

# sa-builder, at the unipept-index commit this image records, with stable Rust: the clone's
# rust-toolchain.toml, whose nightly is for rustfmt, is removed. Its libsais64-rs builds libsais
# with cmake and generates the bindings with bindgen, which needs libclang.
FROM rust:1-trixie AS sa-builder
ARG UNIPEPT_INDEX_COMMIT=07ab4f2f834cf7f85d696a2d8fa210b95d611f99
RUN apt-get update -qq \
 && apt-get install -y -qq --no-install-recommends clang cmake libclang-dev \
 && rm -rf /var/lib/apt/lists/*
RUN git clone --quiet https://github.com/unipept/unipept-index.git /src \
 && git -C /src checkout --quiet "$UNIPEPT_INDEX_COMMIT" \
 && rm /src/rust-toolchain.toml
WORKDIR /src
RUN cargo build --release --locked -p sa-builder

# umgap, at the version CI's umgap suite installs.
FROM rust:1-trixie AS umgap
ARG UMGAP_VERSION=1.2.0
RUN cargo install --locked --version "$UMGAP_VERSION" umgap

FROM debian:trixie-slim
RUN apt-get update -qq \
 && apt-get install -y -qq --no-install-recommends \
      ca-certificates curl gawk libxml2-utils lz4 pigz pv python3 python3-requests unzip \
      uuid-runtime zip \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /opt/unipept-database
# The pipelines use these programs instead of building them (build_binaries in pipelines/lib/common.sh).
ENV PREBUILT_BINARIES=true
COPY --from=sa-builder /src/target/release/sa-builder /usr/local/bin/
COPY --from=umgap /usr/local/cargo/bin/umgap /usr/local/bin/
COPY --from=workspace /out/ target/release/
COPY assets assets
COPY pipelines pipelines
COPY opensearch opensearch
