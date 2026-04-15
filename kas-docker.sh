#!/usr/bin/env bash
# =============================================================================
# kas-docker.sh — Build & push Yocto SDK Docker image for Jetson Orin Nano
# =============================================================================
# Builds drdeshmukh97/yocto-orin:{tag} and pushes to Docker Hub.
#
# Usage:
#   ./kas-docker.sh                      # Build & push :head only
#   ./kas-docker.sh --stable             # Build & push :head + :stable + :latest
#   ./kas-docker.sh --tag v1.0.0         # Build & push with custom tag
#   ./kas-docker.sh --no-push            # Build only, skip push
#   ./kas-docker.sh --sdk-installer path # Use pre-built SDK installer (skip full Yocto build)
# =============================================================================
set -euo pipefail

# ── Configuration ────────────────────────────────────────────────────────────
REPO="drdeshmukh97/yocto-orin"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PUSH="yes"
STABLE="no"
CUSTOM_TAG=""
SDK_INSTALLER=""
BUILD_ARGS=()

# ── Color helpers ────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()   { echo -e "${RED}[FATAL]${NC} $*" >&2; exit 1; }
step()  { echo -e "${CYAN}[STEP]${NC}  $*"; }

# ── Usage ────────────────────────────────────────────────────────────────────
usage() {
    cat <<'EOF'
Usage: ./kas-docker.sh [OPTIONS]

Options:
  --stable                 Tag and push both :stable and :head (+ :latest aliases to :stable)
  --tag NAME               Custom tag name (default: head)
  --no-push                Build the Docker image but do not push to registry
  --sdk-installer PATH     Path to pre-built SDK installer .sh file
                           (skips the full Yocto build inside Docker — much faster)
  -h, --help               Show this help

Workflow:
  FAST (recommended):
    1. Build SDK locally:  ./build.sh -- --target demo-image-base -c populate_sdk
    2. Find installer:     ls build/tmp/deploy/sdk/*.sh
    3. Build container:    ./kas-docker.sh --sdk-installer build/tmp/deploy/sdk/poky-*.sh

  FULL (CI):
    ./kas-docker.sh        # Runs entire Yocto build inside Docker (4-8+ hours)
EOF
    exit 0
}

# ── Argument parsing ─────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --stable)        STABLE="yes"; shift ;;
        --tag)           CUSTOM_TAG="$2"; shift 2 ;;
        --no-push)       PUSH="no"; shift ;;
        --sdk-installer) SDK_INSTALLER="$2"; shift 2 ;;
        -h|--help)       usage ;;
        *)               die "Unknown option: $1" ;;
    esac
done

# ── Validate ─────────────────────────────────────────────────────────────────
command -v docker >/dev/null 2>&1 || die "docker not found. Install Docker Engine first."

if [[ "$PUSH" == "yes" ]]; then
    docker info 2>/dev/null | grep -q "Username" || {
        warn "Not logged in to Docker Hub. Run: docker login"
        warn "Continuing — push will fail if not authenticated."
    }
fi

# ── Determine build target ──────────────────────────────────────────────────
HEAD_TAG="${CUSTOM_TAG:-head}"

if [[ -n "$SDK_INSTALLER" ]]; then
    [[ -f "$SDK_INSTALLER" ]] || die "SDK installer not found: $SDK_INSTALLER"
    info "Using pre-built SDK installer: $SDK_INSTALLER"
    BUILD_ARGS+=(--build-arg "SDK_INSTALLER=${SDK_INSTALLER}")
    # Only build the sdk stage (skip the builder stage)
    BUILD_ARGS+=(--target sdk)
fi

# ── Build ────────────────────────────────────────────────────────────────────
step "Building Docker image: ${REPO}:${HEAD_TAG}"

DOCKER_BUILDKIT=1 docker build \
    "${BUILD_ARGS[@]}" \
    -t "${REPO}:${HEAD_TAG}" \
    -f "${SCRIPT_DIR}/Dockerfile" \
    "${SCRIPT_DIR}"

info "Build complete: ${REPO}:${HEAD_TAG}"

# ── Tag ──────────────────────────────────────────────────────────────────────
TAGS_TO_PUSH=("${HEAD_TAG}")

if [[ "$STABLE" == "yes" ]]; then
    step "Tagging :stable and :latest"
    docker tag "${REPO}:${HEAD_TAG}" "${REPO}:stable"
    docker tag "${REPO}:${HEAD_TAG}" "${REPO}:latest"
    TAGS_TO_PUSH+=("stable" "latest")
    info "Tagged: ${REPO}:stable, ${REPO}:latest"
fi

# ── Push ─────────────────────────────────────────────────────────────────────
if [[ "$PUSH" == "yes" ]]; then
    for tag in "${TAGS_TO_PUSH[@]}"; do
        step "Pushing: ${REPO}:${tag}"
        docker push "${REPO}:${tag}"
    done

    echo ""
    info "┌─────────────────────────────────────────────┐"
    info "│  Push complete                               │"
    info "├─────────────────────────────────────────────┤"
    for tag in "${TAGS_TO_PUSH[@]}"; do
        DIGEST=$(docker inspect --format='{{index .RepoDigests 0}}' "${REPO}:${tag}" 2>/dev/null || echo "n/a")
        info "│  ${REPO}:${tag}"
        info "│    → ${DIGEST}"
    done
    info "└─────────────────────────────────────────────┘"
else
    warn "Push skipped (--no-push). Images built locally only."
    echo ""
    info "To push manually:"
    for tag in "${TAGS_TO_PUSH[@]}"; do
        info "  docker push ${REPO}:${tag}"
    done
fi

echo ""
info "Done. Pull with: docker pull ${REPO}:${HEAD_TAG}"
