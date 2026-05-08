#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE="${IMAGE:-carlosfarkas/lazyslide-histoplus}"
TAG="${TAG:-latest}"
FLAVOR="${FLAVOR:-both}"
PUSH_FLAG=()
NO_CACHE_FLAG=()
EXTRA_ARGS=()

usage() {
  cat <<USAGE
Usage:
  ./build_and_push.sh [options]

Options:
  --image NAME                 Default: ${IMAGE}
  --tag TAG                    Default: ${TAG}
  --flavor auto|both|gpu|cpu   Default: ${FLAVOR}
  --push                       Push after build.
  --no-cache                   Build without Docker cache.
  --torch-cuda CUDA            Forward to setup_server.sh.
  --python-version VERSION     Forward to setup_server.sh.
  --lazyslide-version VERSION  Forward to setup_server.sh.
  --models-ref REF             Forward to setup_server.sh.
  -h, --help                   Show this help.

Examples:
  ./build_and_push.sh --flavor both --image carlosfarkas/lazyslide-histoplus --tag latest
  ./build_and_push.sh --flavor both --image carlosfarkas/lazyslide-histoplus --tag latest --push
USAGE
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --image) IMAGE="${2:?Missing value for --image}"; shift 2 ;;
    --tag) TAG="${2:?Missing value for --tag}"; shift 2 ;;
    --flavor) FLAVOR="${2:?Missing value for --flavor}"; shift 2 ;;
    --push) PUSH_FLAG=(--push); shift ;;
    --no-cache) NO_CACHE_FLAG=(--no-cache); shift ;;
    --torch-cuda|--python-version|--lazyslide-version|--models-ref)
      EXTRA_ARGS+=("$1" "${2:?Missing value for $1}")
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: Unknown option: $1" >&2; exit 1 ;;
  esac
done

exec "${SCRIPT_DIR}/setup_server.sh" \
  --build \
  --flavor "$FLAVOR" \
  --image "$IMAGE" \
  --tag "$TAG" \
  "${NO_CACHE_FLAG[@]}" \
  "${EXTRA_ARGS[@]}" \
  "${PUSH_FLAG[@]}"
