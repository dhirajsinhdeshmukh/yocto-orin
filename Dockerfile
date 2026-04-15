# =============================================================================
# Dockerfile — Yocto SDK for Jetson Orin Nano (aarch64 cross-compilation)
# =============================================================================
# Two usage modes:
#
#   1. PRE-BUILT SDK (fast, recommended):
#      Build the SDK locally first:
#        ./build.sh -- --target demo-image-base -c populate_sdk
#      Then build the Docker image:
#        docker build --build-arg SDK_INSTALLER=build/tmp/deploy/sdk/poky-*.sh -t drdeshmukh97/yocto-orin:head .
#
#   2. FULL BUILD (slow, CI-oriented):
#      docker build --target builder -t yocto-builder .
#      docker build -t drdeshmukh97/yocto-orin:head .
#      (This builds the entire BSP + SDK inside Docker — expect 4–8+ hours)
#
# Base: ubuntu:22.04 — matches Yocto scarthgap (5.0) host requirements.
# Aggressively stripped in the SDK stage to minimize image size (~1.5–2 GB).
# =============================================================================

# ---------------------------------------------------------------------------
# Stage 1: builder — full Yocto build environment (only used for full-build mode)
# ---------------------------------------------------------------------------
FROM ubuntu:22.04 AS builder

ARG DEBIAN_FRONTEND=noninteractive

# Yocto host dependencies (scarthgap)
RUN apt-get update && apt-get install -y --no-install-recommends \
        gawk wget git diffstat unzip texinfo gcc g++ build-essential \
        chrpath socat cpio python3 python3-pip python3-pexpect \
        xz-utils debianutils iputils-ping libsdl1.2-dev xterm \
        python3-git python3-jinja2 python3-subunit python3-setuptools \
        mesa-common-dev zstd liblz4-tool lz4 file locales \
        ca-certificates sudo iproute2 \
    && rm -rf /var/lib/apt/lists/*

# Locale
RUN locale-gen en_US.UTF-8
ENV LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

# Install kas
RUN pip3 install --no-cache-dir kas

# Non-root build user (Yocto requirement)
RUN useradd -m -s /bin/bash -u 1000 yocto \
    && echo "yocto ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

# Copy project source
COPY --chown=yocto:yocto . /work
WORKDIR /work
USER yocto

# Generate signing keys for dm-verity (build-time only — NOT for production)
RUN mkdir -p keys/dm-verity \
    && openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 \
       -out keys/dm-verity/rsa3k-key.pem 2>/dev/null \
    && openssl req -new -x509 -key keys/dm-verity/rsa3k-key.pem \
       -out keys/dm-verity/rsa3k-cert.pem -days 3650 \
       -subj "/CN=dm-verity-docker-build" 2>/dev/null

# Build the image + SDK
RUN kas build kas-project.yml \
    && kas build --target demo-image-base -c populate_sdk kas-project.yml

# ---------------------------------------------------------------------------
# Stage 2: sdk — slim runtime image containing only the cross-compilation SDK
# ---------------------------------------------------------------------------
FROM ubuntu:22.04 AS sdk

ARG DEBIAN_FRONTEND=noninteractive

# SDK installer path — override if using a pre-built SDK from host
ARG SDK_INSTALLER=""

# Minimal runtime dependencies for cross-compilation
RUN apt-get update && apt-get install -y --no-install-recommends \
        python3 python3-pip gcc g++ make cmake ninja-build \
        file xz-utils wget ca-certificates git \
        libssl-dev pkg-config \
    && rm -rf /var/lib/apt/lists/* \
    && rm -rf /usr/share/doc /usr/share/man /usr/share/info

# Locale
RUN apt-get update && apt-get install -y --no-install-recommends locales \
    && locale-gen en_US.UTF-8 \
    && rm -rf /var/lib/apt/lists/*
ENV LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

# Copy SDK installer — from builder stage or from host via build-arg
COPY --from=builder /work/build/tmp/deploy/sdk/poky-glibc-x86_64-demo-image-base-aarch64-jetson-orin-nano-devkit-nvme-toolchain-*.sh /tmp/sdk-installer.sh*
COPY ${SDK_INSTALLER:-/dev/null} /tmp/sdk-installer-host.sh*

# Install the SDK (prefer host-provided, fall back to builder output)
RUN set -e; \
    if [ -f /tmp/sdk-installer-host.sh ]; then \
        INSTALLER=/tmp/sdk-installer-host.sh; \
    elif ls /tmp/sdk-installer.sh* 1>/dev/null 2>&1; then \
        INSTALLER=$(ls /tmp/sdk-installer.sh* | head -1); \
    else \
        echo "ERROR: No SDK installer found. Build with stage 1 or provide SDK_INSTALLER arg." >&2; \
        exit 1; \
    fi; \
    chmod +x "$INSTALLER"; \
    "$INSTALLER" -y -d /opt/yocto-sdk; \
    rm -f /tmp/sdk-installer*.sh*

# Verify SDK installation
RUN test -d /opt/yocto-sdk/sysroots && \
    ls /opt/yocto-sdk/environment-setup-* >/dev/null 2>&1

# Clean up to minimize image size
RUN rm -rf /tmp/* /var/tmp/* /root/.cache

# ---------------------------------------------------------------------------
# Runtime configuration
# ---------------------------------------------------------------------------
LABEL maintainer="drdeshmukh97" \
      org.opencontainers.image.title="Yocto SDK for Jetson Orin Nano" \
      org.opencontainers.image.description="Cross-compilation toolchain for aarch64 Jetson Orin Nano (scarthgap BSP)" \
      org.opencontainers.image.vendor="Physical AI" \
      org.opencontainers.image.source="https://github.com/drdeshmukh97/yocto-orin" \
      target.machine="jetson-orin-nano-devkit-nvme" \
      target.arch="aarch64" \
      yocto.release="scarthgap"

WORKDIR /work

# Source the SDK environment on container start
ENTRYPOINT ["/bin/bash", "-c", "source /opt/yocto-sdk/environment-setup-* && exec \"$@\"", "--"]
CMD ["/bin/bash"]
