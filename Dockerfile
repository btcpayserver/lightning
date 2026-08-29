# syntax=docker/dockerfile:1.7-labs

FROM --platform=${BUILDPLATFORM} debian:bookworm-slim AS base-host

SHELL ["/bin/bash", "-euo", "pipefail", "-c"]

FROM --platform=${TARGETPLATFORM} debian:bookworm-slim AS base-target

SHELL ["/bin/bash", "-euo", "pipefail", "-c"]

FROM base-host AS downloader-linux-amd64

ARG target_arch=x86_64-linux-gnu

FROM base-host AS downloader-linux-arm64

ARG target_arch=aarch64-linux-gnu

FROM base-host AS downloader-linux-arm

ARG target_arch=arm-linux-gnueabihf

FROM downloader-${TARGETOS}-${TARGETARCH} AS downloader

RUN apt-get update && \
    apt-get install -qq -y --no-install-recommends \
        gnupg

ARG BITCOIN_VERSION=27.1
ARG BITCOIN_URL=https://bitcoincore.org/bin/bitcoin-core-${BITCOIN_VERSION}
ARG BITCOIN_TARBALL=bitcoin-${BITCOIN_VERSION}-${target_arch}.tar.gz

WORKDIR /opt/bitcoin

ADD ${BITCOIN_URL}/${BITCOIN_TARBALL}    .
ADD ${BITCOIN_URL}/SHA256SUMS            .
ADD ${BITCOIN_URL}/SHA256SUMS.asc        .
COPY contrib/keys/bitcoin/               gpg/

RUN gpg --quiet --import gpg/* && \
    gpg --verify SHA256SUMS.asc SHA256SUMS && \
    sha256sum -c SHA256SUMS --ignore-missing

RUN tar xzf ${BITCOIN_TARBALL} --strip-components=1

FROM base-host AS lightning-downloader-linux-amd64

ARG cln_release_arch=amd64
ARG cln_release_sha256=53ddf124fe7058b6a2fc059d104976cc54ba5be21dc55b295cd82d01cabeb39c

FROM base-host AS lightning-downloader-linux-arm64

ARG cln_release_arch=arm64
ARG cln_release_sha256=a6e89d49468dac83122d6b795796b7f2ebb55eab6181b419f1cf9a73aeae3965

FROM base-host AS lightning-downloader-linux-arm

FROM base-host AS base-builder

RUN apt-get update && \
    apt-get install -qq -y --no-install-recommends \
        build-essential \
        ca-certificates \
        wget \
        git \
        autoconf \
        automake \
        bison \
        flex \
        jq \
        libtool \
        gettext \
        protobuf-compiler

WORKDIR /opt

ADD --chmod=750 https://astral.sh/uv/install.sh      install-uv.sh
ADD --chmod=750 https://sh.rustup.rs                 install-rust.sh

WORKDIR /opt/lightningd

COPY --exclude=.git/ . .

FROM base-builder AS base-builder-linux-amd64

ARG target_arch=x86_64-linux-gnu
ARG target_arch_gcc=x86-64-linux-gnu
ARG target_arch_dpkg=amd64
ARG target_arch_rust=x86_64-unknown-linux-gnu
ARG COPTFLAGS="-O2 -march=x86-64"

FROM base-builder AS base-builder-linux-arm64

ARG target_arch=aarch64-linux-gnu
ARG target_arch_gcc=aarch64-linux-gnu
ARG target_arch_dpkg=arm64
ARG target_arch_rust=aarch64-unknown-linux-gnu
ARG COPTFLAGS="-O2 -march=armv8-a"

FROM base-builder AS base-builder-linux-arm

ARG target_arch=arm-linux-gnueabihf
ARG target_arch_gcc=arm-linux-gnueabihf
ARG target_arch_dpkg=armhf
ARG target_arch_rust=armv7-unknown-linux-gnueabihf
ARG COPTFLAGS="-O2 -march=armv7-a -mfpu=vfpv3-d16 -mfloat-abi=hard"

FROM lightning-downloader-${TARGETOS}-${TARGETARCH} AS builder

ARG TARGETOS
ARG TARGETARCH
ARG cln_release_arch
ARG cln_release_sha256
ARG LIGHTNINGD_VERSION=v26.06.7
ARG CLN_RELEASE_URL=https://github.com/ElementsProject/lightning/releases/download/${LIGHTNINGD_VERSION}
ARG CLN_TARBALL=clightning-${LIGHTNINGD_VERSION}-Ubuntu-22.04-${cln_release_arch}.tar.xz

RUN test -n "${cln_release_arch}" || \
    (echo "No Core Lightning ${LIGHTNINGD_VERSION} release binary is available for ${TARGETOS}/${TARGETARCH}" >&2; exit 1)

WORKDIR /opt/lightning-release

ADD ${CLN_RELEASE_URL}/${CLN_TARBALL} .

RUN apt-get update && \
    apt-get install -qq -y --no-install-recommends xz-utils && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* && \
    echo "${cln_release_sha256}  ${CLN_TARBALL}" | sha256sum -c - && \
    mkdir -p /tmp/lightning_install && \
    tar -xJf ${CLN_TARBALL} -C /tmp/lightning_install --strip-components=2

# VLS builder stage (only used by lightningd-vls-signer)
FROM base-builder-${TARGETOS}-${TARGETARCH} AS vls-builder

# First declare the variables that come from parent stages
ARG target_arch
ARG target_arch_gcc
ARG target_arch_dpkg
ARG target_arch_rust
ARG COPTFLAGS

# Then declare the tool variables using the target_arch
ARG AR=${target_arch}-ar
ARG AS=${target_arch}-as
ARG CC=${target_arch}-gcc
ARG CXX=${target_arch}-g++
ARG LD=${target_arch}-ld
ARG STRIP=${target_arch}-strip
ARG TARGET=${target_arch_rust}
ARG RUST_PROFILE=release
ARG VERSION
ARG VLS_VERSION=v0.14.0

# Install cross-compilation toolchain (same as builder stage)
RUN dpkg --add-architecture ${target_arch_dpkg}

RUN apt-get update && \
    apt-get install -qq -y --no-install-recommends \
        pkg-config:${target_arch_dpkg} \
        crossbuild-essential-${target_arch_dpkg} && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

ENV PATH="/root/.cargo/bin:/root/.local/bin:${PATH}"
ENV PKG_CONFIG_PATH=/usr/lib/${target_arch}/pkgconfig
ENV PKG_CONFIG_LIBDIR=/usr/lib/${target_arch}/pkgconfig

WORKDIR /opt

RUN ./install-uv.sh -q
RUN ./install-rust.sh -y -q --profile minimal --component rustfmt --target ${target_arch_rust}

RUN git clone --depth 1 --branch ${VLS_VERSION} https://gitlab.com/lightning-signer/validating-lightning-signer.git
WORKDIR /opt/validating-lightning-signer

RUN mkdir -p .cargo && tee .cargo/config.toml <<EOF

[build]
target = "${target_arch_rust}"
rustflags = ["-C", "target-cpu=generic"]

[target.${target_arch_rust}]
linker = "${CC}"

EOF

RUN cargo build --release --target ${target_arch_rust}

RUN cp -r ./target/${target_arch_rust}/release/ /tmp/vls_install/ \
    && find /tmp/vls_install -type f -executable -exec \
    file {} + | \
    awk -F: '/ELF/ {print $1}' | \
    xargs -r ${STRIP} --strip-unneeded

# Standard Lightning image (without VLS)
FROM base-target AS lightningd

RUN apt-get update && \
    apt-get install -qq -y --no-install-recommends \
        inotify-tools \
        socat \
        jq \
        libpq5 \
        libsqlite3-0 \
        libsodium23 && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

COPY --from=downloader    /opt/bitcoin/bin/bitcoin-cli          /usr/bin/
COPY --from=builder       /tmp/lightning_install/               /usr/local/

COPY tools/docker-entrypoint.sh    /entrypoint.sh

ENV LIGHTNINGD_DATA=/root/.lightning
ENV LIGHTNINGD_RPC_PORT=9835
ENV LIGHTNINGD_PORT=9735
ENV LIGHTNINGD_NETWORK=bitcoin

RUN mkdir $LIGHTNINGD_DATA && \
    mkdir $LIGHTNINGD_DATA/plugins && \
    touch $LIGHTNINGD_DATA/config

EXPOSE 9735 9835
VOLUME ["/root/.lightning"]
ENTRYPOINT ["/entrypoint.sh"]

# Lightning with VLS Signer
FROM base-target AS lightningd-vls-signer

RUN apt-get update && \
    apt-get install -qq -y --no-install-recommends \
        inotify-tools \
        socat \
        jq \
        libpq5 \
        libsqlite3-0 \
        libsodium23 && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

COPY --from=downloader    /opt/bitcoin/bin/bitcoin-cli          /usr/bin/
COPY --from=builder       /tmp/lightning_install/               /usr/local/
COPY --from=vls-builder   /tmp/vls_install/remote_hsmd_socket   /var/lib/vls/bin/

COPY tools/docker-entrypoint.sh    /entrypoint.sh

ENV LIGHTNINGD_DATA=/root/.lightning
ENV LIGHTNINGD_RPC_PORT=9835
ENV LIGHTNINGD_PORT=9735
ENV LIGHTNINGD_NETWORK=bitcoin
ENV VLS_ENABLED=true

EXPOSE 9735 9835
VOLUME ["/root/.lightning"]
ENTRYPOINT ["/entrypoint.sh"]

# Default target (for backward compatibility)
FROM lightningd AS final
