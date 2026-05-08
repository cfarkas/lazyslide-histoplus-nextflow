# syntax=docker/dockerfile:1.6

ARG PYTHON_VERSION=3.11
FROM python:${PYTHON_VERSION}-slim-bookworm

ARG FLAVOR=cpu
ARG TORCH_CUDA=cu124
ARG LAZYSLIDE_VERSION=0.10.1
ARG LAZYSLIDE_MODELS_REF=main

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1 \
    HF_HOME=/home/lazyslide/.cache/huggingface \
    HUGGINGFACE_HUB_CACHE=/home/lazyslide/.cache/huggingface/hub \
    MPLBACKEND=Agg \
    JAVA_HOME=/usr/lib/jvm/default-java

RUN apt-get update && apt-get install -y --no-install-recommends \
      bash ca-certificates curl git tini default-jre-headless \
      build-essential pkg-config procps \
      libgl1 libglib2.0-0 libgomp1 \
      libjpeg62-turbo libtiff6 \
      libopenslide0 openslide-tools \
      libvips42 libvips-tools \
    && rm -rf /var/lib/apt/lists/*

RUN --mount=type=cache,target=/root/.cache/pip \
    python -m pip install --upgrade pip setuptools wheel

# Install PyTorch first so the CPU/GPU choice is deterministic.
RUN --mount=type=cache,target=/root/.cache/pip \
    if [ "${FLAVOR}" = "gpu" ]; then \
      python -m pip install --prefer-binary \
        --index-url "https://download.pytorch.org/whl/${TORCH_CUDA}" \
        torch torchvision torchaudio; \
    else \
      python -m pip install --prefer-binary \
        --index-url "https://download.pytorch.org/whl/cpu" \
        torch torchvision torchaudio; \
    fi

COPY requirements.txt /tmp/requirements.txt
COPY constraints.txt /tmp/constraints.txt

# Important build fix:
#   * Do not install the legacy PyPI package "instanseg" here; it pulls old
#     numpy constraints and caused pip resolution-too-deep/backtracking.
#   * Do not install owkin/histoplus as a separate package; LazySlide's
#     lazyslide-models repository contains the HistoPLUS wrapper and downloads
#     gated weights at runtime using HF_TOKEN.
#   * Install lazyslide-models from GitHub before lazyslide, because the
#     lazyslide wheel depends on that distribution name.
RUN --mount=type=cache,target=/root/.cache/pip \
    python -m pip install --prefer-binary --constraint /tmp/constraints.txt \
      "git+https://github.com/rendeirolab/lazyslide-models.git@${LAZYSLIDE_MODELS_REF}" \
    && python -m pip install --prefer-binary --constraint /tmp/constraints.txt \
      "lazyslide==${LAZYSLIDE_VERSION}" \
    && python -m pip install --prefer-binary --constraint /tmp/constraints.txt \
      -r /tmp/requirements.txt \
    && python -m pip check

RUN useradd --create-home --shell /bin/bash lazyslide \
    && mkdir -p /opt/lazyslide /home/lazyslide/.cache/huggingface \
    && chown -R lazyslide:lazyslide /opt/lazyslide /home/lazyslide

COPY lazyslide_histoplus_wsi_celltype.py /opt/lazyslide/lazyslide_histoplus_wsi_celltype.py

RUN chmod +x /opt/lazyslide/lazyslide_histoplus_wsi_celltype.py \
    && python - <<'PY'
from wsidata import open_wsi
import lazyslide as zs
try:
    from lazyslide.models import list_models
except Exception:
    from lazyslide_models import list_models
try:
    models = set(list_models(task="segmentation"))
except TypeError:
    models = set(list_models("segmentation"))
print("LazySlide import OK:", getattr(zs, "__version__", "unknown"))
print("WSIData import OK")
print("Segmentation models detected:", sorted(m for m in models if m in {"histoplus", "instanseg", "nulite"}))
assert "histoplus" in models, "HistoPLUS model was not registered by lazyslide-models"
PY

WORKDIR /opt/lazyslide
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/bin/bash"]
