#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE="${IMAGE:-carlosfarkas/lazyslide-histoplus}"
TAG="${TAG:-latest}"
FLAVOR="${FLAVOR:-auto}"
PUSH="false"
DO_INSTALL="false"
DO_BUILD="false"
CHECK_ONLY="false"
INSTALL_GITHUB_CLI="false"
NO_BUILD="false"
TORCH_CUDA="${TORCH_CUDA:-cu124}"
PYTHON_VERSION="${PYTHON_VERSION:-3.11}"
LAZYSLIDE_VERSION="${LAZYSLIDE_VERSION:-0.10.1}"
LAZYSLIDE_MODELS_REF="${LAZYSLIDE_MODELS_REF:-main}"
NO_CACHE="false"

log() { printf '\n\033[1;34m[%s]\033[0m %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
warn() { printf '\n\033[1;33mWARNING:\033[0m %s\n' "$*" >&2; }
fail() { printf '\n\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || fail "Missing command: $1"; }

usage() {
  cat <<USAGE
Usage:
  ./setup_server.sh [options]

Actions:
  --check-only                 Print environment status only.
  --install                    Install/check Docker, Nextflow, and optional tools.
  --build                      Build Docker image(s).
  --push                       Push built image(s) to Docker Hub.
  --no-build                   Use with --install when you only want dependencies.
  --install-github-cli         Install GitHub CLI if missing.

Build options:
  --flavor auto|both|gpu|cpu   Default: ${FLAVOR}
  --image NAME                 Default: ${IMAGE}
  --tag TAG                    Default: ${TAG}
  --torch-cuda CUDA            PyTorch CUDA wheel suffix. Default: ${TORCH_CUDA}
  --python-version VERSION     Default: ${PYTHON_VERSION}
  --lazyslide-version VERSION  Default: ${LAZYSLIDE_VERSION}
  --models-ref REF             lazyslide-models Git ref. Default: ${LAZYSLIDE_MODELS_REF}
  --no-cache                   Pass --no-cache to docker build.

Examples:
  ./setup_server.sh --check-only
  ./setup_server.sh --install --flavor auto --image carlosfarkas/lazyslide-histoplus --tag latest
  ./setup_server.sh --build --flavor both --image carlosfarkas/lazyslide-histoplus --tag latest
  ./setup_server.sh --build --flavor both --image carlosfarkas/lazyslide-histoplus --tag latest --push
USAGE
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --check-only) CHECK_ONLY="true"; shift ;;
    --install) DO_INSTALL="true"; shift ;;
    --build) DO_BUILD="true"; shift ;;
    --push) PUSH="true"; shift ;;
    --no-build) NO_BUILD="true"; shift ;;
    --install-github-cli) INSTALL_GITHUB_CLI="true"; shift ;;
    --flavor) FLAVOR="${2:?Missing value for --flavor}"; shift 2 ;;
    --image) IMAGE="${2:?Missing value for --image}"; shift 2 ;;
    --tag) TAG="${2:?Missing value for --tag}"; shift 2 ;;
    --torch-cuda) TORCH_CUDA="${2:?Missing value for --torch-cuda}"; shift 2 ;;
    --python-version) PYTHON_VERSION="${2:?Missing value for --python-version}"; shift 2 ;;
    --lazyslide-version) LAZYSLIDE_VERSION="${2:?Missing value for --lazyslide-version}"; shift 2 ;;
    --models-ref) LAZYSLIDE_MODELS_REF="${2:?Missing value for --models-ref}"; shift 2 ;;
    --no-cache) NO_CACHE="true"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) fail "Unknown option: $1" ;;
  esac
done

have_sudo() { command -v sudo >/dev/null 2>&1; }
sudo_run() {
  if [[ "${EUID}" -eq 0 ]]; then
    "$@"
  elif have_sudo; then
    sudo "$@"
  else
    fail "Need root/sudo for: $*"
  fi
}

install_docker() {
  if command -v docker >/dev/null 2>&1; then
    log "Docker already installed: $(docker --version)"
    return
  fi
  log "Installing Docker using the official convenience script"
  curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
  sudo_run sh /tmp/get-docker.sh
  if [[ "${EUID}" -ne 0 ]]; then
    sudo_run usermod -aG docker "${USER}"
    warn "User ${USER} was added to the docker group. Run: newgrp docker"
  fi
}

install_nextflow() {
  if command -v nextflow >/dev/null 2>&1; then
    log "Nextflow already installed: $(nextflow -version | head -n 1 || true)"
    return
  fi
  log "Installing Nextflow"
  curl -fsSL https://get.nextflow.io -o /tmp/get-nextflow.sh
  bash /tmp/get-nextflow.sh
  chmod +x nextflow
  sudo_run mv nextflow /usr/local/bin/nextflow
}

install_gh() {
  if command -v gh >/dev/null 2>&1; then
    log "GitHub CLI already installed: $(gh --version | head -n 1)"
    return
  fi
  log "Installing GitHub CLI"
  if command -v apt-get >/dev/null 2>&1; then
    sudo_run apt-get update
    sudo_run apt-get install -y curl ca-certificates gnupg
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo_run dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg >/dev/null
    sudo_run chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo_run tee /etc/apt/sources.list.d/github-cli.list >/dev/null
    sudo_run apt-get update
    sudo_run apt-get install -y gh
  else
    fail "Automatic gh install currently supports apt-get systems only. Install gh manually and rerun."
  fi
}

configure_nvidia_runtime() {
  if ! command -v nvidia-smi >/dev/null 2>&1; then
    warn "nvidia-smi not found. GPU Docker runtime configuration skipped."
    return
  fi
  if command -v nvidia-ctk >/dev/null 2>&1; then
    log "Configuring NVIDIA Container Toolkit runtime"
    sudo_run nvidia-ctk runtime configure --runtime=docker || warn "nvidia-ctk runtime configure failed"
    if command -v systemctl >/dev/null 2>&1; then
      sudo_run systemctl restart docker || warn "Could not restart docker with systemctl"
    fi
  else
    warn "nvidia-ctk not found. Install NVIDIA Container Toolkit if GPU containers fail."
  fi
}

check_env() {
  log "Environment check"
  echo "Repository:             $SCRIPT_DIR"
  echo "Image:                  $IMAGE:$TAG"
  echo "Flavor:                 $FLAVOR"
  echo "PyTorch CUDA suffix:    $TORCH_CUDA"
  echo "Python version:         $PYTHON_VERSION"
  echo "LazySlide version:      $LAZYSLIDE_VERSION"
  echo "lazyslide-models ref:   $LAZYSLIDE_MODELS_REF"
  echo
  command -v docker >/dev/null 2>&1 && docker --version || echo "docker: missing"
  command -v nextflow >/dev/null 2>&1 && nextflow -version | head -n 1 || echo "nextflow: missing"
  command -v gh >/dev/null 2>&1 && gh --version | head -n 1 || echo "gh: missing"
  command -v git >/dev/null 2>&1 && git --version || echo "git: missing"
  command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi --query-gpu=name,driver_version --format=csv,noheader || echo "nvidia-smi: missing"
  [[ -f "$SCRIPT_DIR/Dockerfile" ]] && echo "Dockerfile: present" || echo "Dockerfile: missing"
  [[ -f "$SCRIPT_DIR/requirements.txt" ]] && echo "requirements.txt: present" || echo "requirements.txt: missing"
  [[ -f "$SCRIPT_DIR/constraints.txt" ]] && echo "constraints.txt: present" || echo "constraints.txt: missing"
  [[ -f "$SCRIPT_DIR/main.nf" ]] && echo "main.nf: present" || echo "main.nf: missing"
  [[ -x "$SCRIPT_DIR/run.sh" ]] && echo "run.sh: executable" || echo "run.sh: missing/not executable"
}

choose_auto_flavor() {
  if command -v nvidia-smi >/dev/null 2>&1; then
    echo gpu
  else
    echo cpu
  fi
}

build_one() {
  local flavor="$1" image_tag="$2"
  local cache_args=()
  [[ "$NO_CACHE" == "true" ]] && cache_args+=(--no-cache)

  log "Building ${image_tag} flavor=${flavor}"
  DOCKER_BUILDKIT=1 docker build \
    "${cache_args[@]}" \
    --build-arg "FLAVOR=${flavor}" \
    --build-arg "TORCH_CUDA=${TORCH_CUDA}" \
    --build-arg "PYTHON_VERSION=${PYTHON_VERSION}" \
    --build-arg "LAZYSLIDE_VERSION=${LAZYSLIDE_VERSION}" \
    --build-arg "LAZYSLIDE_MODELS_REF=${LAZYSLIDE_MODELS_REF}" \
    -t "${image_tag}" \
    -f "${SCRIPT_DIR}/Dockerfile" \
    "${SCRIPT_DIR}"

  if [[ "$PUSH" == "true" ]]; then
    log "Pushing ${image_tag}"
    docker push "${image_tag}"
  fi
}

build_images() {
  need_cmd docker
  case "$FLAVOR" in
    auto)
      local auto_flavor
      auto_flavor="$(choose_auto_flavor)"
      build_one "$auto_flavor" "${IMAGE}:${TAG}"
      ;;
    gpu|docker_gpu)
      build_one gpu "${IMAGE}:${TAG}"
      docker tag "${IMAGE}:${TAG}" "${IMAGE}:${TAG}-gpu"
      [[ "$PUSH" == "true" ]] && docker push "${IMAGE}:${TAG}-gpu"
      ;;
    cpu|docker_cpu)
      build_one cpu "${IMAGE}:${TAG}"
      docker tag "${IMAGE}:${TAG}" "${IMAGE}:${TAG}-cpu"
      [[ "$PUSH" == "true" ]] && docker push "${IMAGE}:${TAG}-cpu"
      ;;
    both)
      build_one gpu "${IMAGE}:${TAG}-gpu"
      build_one cpu "${IMAGE}:${TAG}-cpu"
      if [[ "$(choose_auto_flavor)" == "gpu" ]]; then
        docker tag "${IMAGE}:${TAG}-gpu" "${IMAGE}:${TAG}"
      else
        docker tag "${IMAGE}:${TAG}-cpu" "${IMAGE}:${TAG}"
      fi
      [[ "$PUSH" == "true" ]] && docker push "${IMAGE}:${TAG}"
      ;;
    *) fail "Unknown flavor: $FLAVOR" ;;
  esac
  log "Available local images"
  docker image ls "$IMAGE" || true
}

if [[ "$CHECK_ONLY" == "true" ]]; then
  check_env
  exit 0
fi

if [[ "$DO_INSTALL" == "true" ]]; then
  install_docker
  install_nextflow
  if [[ "$INSTALL_GITHUB_CLI" == "true" ]]; then
    install_gh
  fi
  configure_nvidia_runtime
  check_env
fi

if [[ "$NO_BUILD" == "true" ]]; then
  exit 0
fi

if [[ "$DO_BUILD" == "true" ]]; then
  build_images
fi

if [[ "$DO_INSTALL" != "true" && "$DO_BUILD" != "true" ]]; then
  usage
fi
