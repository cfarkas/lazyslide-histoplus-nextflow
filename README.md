# LazySlide HistoPLUS Nextflow Docker pipeline

This repository builds CPU/GPU Docker images and runs a Nextflow wrapper around
`lazyslide_histoplus_wsi_celltype.py`.

## What this build fixes

- Removes hard-coded Hugging Face, Docker Hub, and GitHub tokens.
- Avoids the previous empty `--exclude` bug by forwarding `--exclude` only when it has a real value.
- Avoids fixed Nextflow `nextflow_report.html` / `nextflow_trace.txt` collisions by using run-specific filenames from `run.sh`.
- Fixes the Docker `pip resolution-too-deep` failure by removing conflicting direct installs of the old PyPI `instanseg` package and the standalone `owkin/histoplus` source package. HistoPLUS is provided through `lazyslide-models` and downloads model weights at runtime with your Hugging Face token.

## Files

```text
Dockerfile                         Docker image recipe for CPU/GPU variants
requirements.txt                   Extra runtime requirements
constraints.txt                    pip resolver lower-bound guardrails
lazyslide_histoplus_wsi_celltype.py Python workflow script
main.nf                            Nextflow entry point
nextflow.config                    Nextflow profiles and safe report/trace overwrite config
run.sh                             User-facing Nextflow launcher
setup_server.sh                    Docker/Nextflow installation and image build helper
build_and_push.sh                  Small wrapper around setup_server.sh --build
github_push.sh                     GitHub HTTPS push helper
commands.txt                       Full command playbook
README.md                          This file
.dockerignore                      Docker build ignore list
.gitignore                         Git ignore list
```

## Quick start

```bash
cd /media/server/STORAGE/Motic_AnatomiaPatológica_2025
unzip -o lazyslide-histoplus-nextflow.zip
cd lazyslide-histoplus-nextflow
chmod +x *.sh lazyslide_histoplus_wsi_celltype.py

./setup_server.sh --check-only
./setup_server.sh --build --flavor both --image carlosfarkas/lazyslide-histoplus --tag latest
```

## Token handling

Create a private Hugging Face token file. Do not paste tokens into shell history,
Git, or shared notes.

```bash
mkdir -p ~/.config/lazyslide-histoplus
nano ~/.config/lazyslide-histoplus/hf_token
chmod 600 ~/.config/lazyslide-histoplus/hf_token
```

`run.sh` automatically reads this file when `HF_TOKEN` is not already set.

## Run examples

Scan only:

```bash
./run.sh \
  --input-dir /media/server/STORAGE/Motic_AnatomiaPatológica_2025/PROYECTO_SUC250067_ARACELLY \
  --output-root /media/server/STORAGE/Motic_AnatomiaPatológica_2025/PROYECTO_SUC250067_ARACELLY/AI_RESULTS_LAZY_HISTOPLUS \
  --scan-only \
  --profile auto \
  --include '*'
```

Full ARACELLY run:

```bash
./run.sh \
  --input-dir /media/server/STORAGE/Motic_AnatomiaPatológica_2025/PROYECTO_SUC250067_ARACELLY \
  --output-root /media/server/STORAGE/Motic_AnatomiaPatológica_2025/PROYECTO_SUC250067_ARACELLY/AI_RESULTS_LAZY_HISTOPLUS \
  --profile auto \
  --include '*' \
  --mpp 0.5 \
  --tile-px 840 \
  --qc-patch-count 12 \
  --run-cells-stage true \
  --export-qupath true
```

## Docker build notes

The Dockerfile installs PyTorch first from the selected CPU/CUDA index, then
installs `lazyslide-models` from GitHub and `lazyslide==0.10.1` from PyPI with
`constraints.txt`. This keeps pip from backtracking through old incompatible
package versions.

To force a clean rebuild after a failed old build:

```bash
docker builder prune -f
./setup_server.sh --build --flavor both --image carlosfarkas/lazyslide-histoplus --tag latest --no-cache
```

## Push to GitHub

```bash
./setup_server.sh --install --no-build --install-github-cli
./github_push.sh --owner cfarkas --repo-name lazyslide-histoplus-nextflow --public
```

## Push to Docker Hub

```bash
docker login
./setup_server.sh --build --flavor both --image carlosfarkas/lazyslide-histoplus --tag latest --push
```
