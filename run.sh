#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPELINE_DIR="${PIPELINE_DIR:-${SCRIPT_DIR}}"

INPUT_DIR=""
OUTPUT_ROOT=""
PROFILE="auto"
CONTAINER_IMAGE="${CONTAINER_IMAGE:-carlosfarkas/lazyslide-histoplus:latest}"
DOCKER_RUN_OPTIONS="${DOCKER_RUN_OPTIONS:-}"
STORAGE_ROOT="${STORAGE_ROOT:-/media/server/STORAGE/Motic_AnatomiaPatológica_2025}"

HF_TOKEN_FILE="${HF_TOKEN_FILE:-${HOME}/.config/lazyslide-histoplus/hf_token}"
HF_HOME="${HF_HOME:-${HOME}/.cache/lazyslide-histoplus/hf}"
HUGGINGFACE_HUB_CACHE="${HUGGINGFACE_HUB_CACHE:-${HF_HOME}/hub}"

INCLUDE="*"
EXCLUDE=""

MPP="0.5"
TILE_PX="840"
DEVICE="cuda"
CELLTYPES_BATCH_SIZE="2"
CELLS_BATCH_SIZE="4"
NUM_WORKERS="0"
CPUS="8"
MEMORY="32 GB"
TIME_LIMIT="72h"

CONVERT_TO_PYRAMIDAL="true"
PYRAMIDAL_COMPRESSION="lzw"
PYRAMIDAL_JPEG_Q="90"
PIPELINE_RESUME="true"
NEXTFLOW_RESUME="true"
OVERWRITE="false"
OVERWRITE_EXPORT="false"
DRY_RUN="false"
SCAN_ONLY="false"
AUTO_EXPORT_MISSING="true"
NO_PROGRESS="false"
STRUCTURE_MAX_DEPTH="5"
EXPORT_QUPATH="false"
QC_PATCH_COUNT="0"
QC_PATCH_SIZE="1024"
RUN_CELLS_STAGE="false"
AMP="false"
LOG_LEVEL="INFO"
SAME_ENV_ONLY="true"
PROCESS_DEBUG="true"

EXPORT_LEVELS="0 2"
EXPORT_TILE="1024"
EXPORT_COMPRESSION="deflate"
EXPORT_COMPRESSION_LEVEL="9"
RAW_EXTENSIONS=".mds .mdsx"
OVERLAP="0.2"
BACKGROUND_FRACTION="0.95"
OPS_LEVEL="0"
TISSUE_LEVEL="auto"
THUMBNAIL_SIZE="2400"
PYRAMIDAL_TILE="512"
CELLS_MODEL="instanseg"
HISTOPLUS_MAGNIFICATION="20x"
HISTOPLUS_REPO_ID="Owkin-Bioptimus/histoplus"
ZOOM_SIZE="2000"
OVERLAY_ALPHA="0.55"
FIGURE_DPI="300"
ZOOM_MAX_POLYGONS="0"
QC_MIN_DISTANCE_FACTOR="0.85"

WITH_REPORT="true"
WITH_TRACE="true"
RUN_ID="${RUN_ID:-$(date +%Y%m%d_%H%M%S)_$$}"

usage() {
  cat <<USAGE
Usage:
  ./run.sh --input-dir PATH [options]

Required:
  --input-dir PATH              Raw Motic/ASlide case folder.

Common options:
  --output-root PATH            Default: <input-dir>/AI_RESULTS_LAZY_HISTOPLUS
  --profile auto|docker_gpu|docker_cpu|gpu|cpu
  --container-image IMAGE       Default: ${CONTAINER_IMAGE}
  --include PATTERN             Default: '*'
  --exclude PATTERN             Optional. Omit completely to disable exclusion.
  --scan-only [true|false]      Scan only; do not run full analysis.
  --export-qupath [true|false]  Export QuPath output.
  --run-cells-stage [true|false]
  --mpp FLOAT                   Default: ${MPP}
  --tile-px INT                 Default: ${TILE_PX}
  --qc-patch-count INT          Default: ${QC_PATCH_COUNT}
  --device cuda|cpu             Default: ${DEVICE}
  --cpus INT                    Default: ${CPUS}
  --memory STRING               Default: '${MEMORY}'
  --time STRING                 Default: ${TIME_LIMIT}

Token/cache options:
  --hf-token-file PATH          Default: ${HF_TOKEN_FILE}
  --storage-root PATH           Host path mounted into Docker. Default: ${STORAGE_ROOT}

Report/cache options:
  --run-id NAME                 Used in nextflow_report_<run-id>.html and nextflow_trace_<run-id>.txt
  --no-report                   Do not write a Nextflow HTML report.
  --no-trace                    Do not write a Nextflow trace file.
  --no-resume                   Disable both Nextflow -resume and Python --resume.

Examples:
  ./run.sh --input-dir /path/to/case --scan-only --include '*'
  ./run.sh --input-dir /path/to/case --include '*' --qc-patch-count 12 --export-qupath true --run-cells-stage true
USAGE
}

fail() { echo "ERROR: $*" >&2; exit 1; }

need_value() {
  local opt="$1" val="${2:-}"
  if [[ -z "${val}" || "${val}" == --* ]]; then
    fail "Missing value for ${opt}"
  fi
}

normalize_bool() {
  case "${1,,}" in
    true|t|yes|y|1|on) echo "true" ;;
    false|f|no|n|0|off) echo "false" ;;
    *) fail "Invalid boolean value: $1" ;;
  esac
}

read_bool_or_true() {
  if [[ "$#" -ge 1 && -n "${1:-}" && "${1:-}" != --* ]]; then
    normalize_bool "$1"
  else
    echo "true"
  fi
}

bool_shift_count() {
  if [[ "$#" -ge 1 && -n "${1:-}" && "${1:-}" != --* ]]; then
    echo 2
  else
    echo 1
  fi
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --input-dir|--target-folder)
      need_value "$1" "${2:-}"; INPUT_DIR="$2"; shift 2 ;;
    --output-root)
      need_value "$1" "${2:-}"; OUTPUT_ROOT="$2"; shift 2 ;;
    --profile)
      need_value "$1" "${2:-}"; PROFILE="$2"; shift 2 ;;
    --container-image)
      need_value "$1" "${2:-}"; CONTAINER_IMAGE="$2"; shift 2 ;;
    --docker-run-options)
      need_value "$1" "${2:-}"; DOCKER_RUN_OPTIONS="$2"; shift 2 ;;
    --storage-root)
      need_value "$1" "${2:-}"; STORAGE_ROOT="$2"; shift 2 ;;
    --hf-token-file)
      need_value "$1" "${2:-}"; HF_TOKEN_FILE="$2"; shift 2 ;;
    --include)
      need_value "$1" "${2:-}"; INCLUDE="$2"; shift 2 ;;
    --exclude)
      need_value "$1" "${2:-}"; EXCLUDE="$2"; shift 2 ;;
    --mpp)
      need_value "$1" "${2:-}"; MPP="$2"; shift 2 ;;
    --tile-px|--tile_px)
      need_value "$1" "${2:-}"; TILE_PX="$2"; shift 2 ;;
    --device)
      need_value "$1" "${2:-}"; DEVICE="$2"; shift 2 ;;
    --celltypes-batch-size|--celltypes_batch_size)
      need_value "$1" "${2:-}"; CELLTYPES_BATCH_SIZE="$2"; shift 2 ;;
    --cells-batch-size|--cells_batch_size)
      need_value "$1" "${2:-}"; CELLS_BATCH_SIZE="$2"; shift 2 ;;
    --num-workers|--num_workers)
      need_value "$1" "${2:-}"; NUM_WORKERS="$2"; shift 2 ;;
    --cpus)
      need_value "$1" "${2:-}"; CPUS="$2"; shift 2 ;;
    --memory)
      need_value "$1" "${2:-}"; MEMORY="$2"; shift 2 ;;
    --time)
      need_value "$1" "${2:-}"; TIME_LIMIT="$2"; shift 2 ;;
    --convert-to-pyramidal|--convert_to_pyramidal)
      CONVERT_TO_PYRAMIDAL="$(read_bool_or_true "${2:-}")"; shift "$(bool_shift_count "${2:-}")" ;;
    --no-convert-to-pyramidal)
      CONVERT_TO_PYRAMIDAL="false"; shift ;;
    --pyramidal-compression|--pyramidal_compression)
      need_value "$1" "${2:-}"; PYRAMIDAL_COMPRESSION="$2"; shift 2 ;;
    --pyramidal-jpeg-q|--pyramidal_jpeg_q)
      need_value "$1" "${2:-}"; PYRAMIDAL_JPEG_Q="$2"; shift 2 ;;
    --resume)
      PIPELINE_RESUME="$(read_bool_or_true "${2:-}")"; NEXTFLOW_RESUME="${PIPELINE_RESUME}"; shift "$(bool_shift_count "${2:-}")" ;;
    --no-resume)
      PIPELINE_RESUME="false"; NEXTFLOW_RESUME="false"; shift ;;
    --overwrite)
      OVERWRITE="$(read_bool_or_true "${2:-}")"; shift "$(bool_shift_count "${2:-}")" ;;
    --overwrite-export|--overwrite_export)
      OVERWRITE_EXPORT="$(read_bool_or_true "${2:-}")"; shift "$(bool_shift_count "${2:-}")" ;;
    --dry-run|--dry_run)
      DRY_RUN="$(read_bool_or_true "${2:-}")"; shift "$(bool_shift_count "${2:-}")" ;;
    --scan-only|--scan_only)
      SCAN_ONLY="$(read_bool_or_true "${2:-}")"; shift "$(bool_shift_count "${2:-}")" ;;
    --auto-export-missing|--auto_export_missing)
      AUTO_EXPORT_MISSING="$(read_bool_or_true "${2:-}")"; shift "$(bool_shift_count "${2:-}")" ;;
    --no-progress|--no_progress)
      NO_PROGRESS="$(read_bool_or_true "${2:-}")"; shift "$(bool_shift_count "${2:-}")" ;;
    --structure-max-depth|--structure_max_depth)
      need_value "$1" "${2:-}"; STRUCTURE_MAX_DEPTH="$2"; shift 2 ;;
    --export-qupath|--export_qupath)
      EXPORT_QUPATH="$(read_bool_or_true "${2:-}")"; shift "$(bool_shift_count "${2:-}")" ;;
    --qc-patch-count|--qc_patch_count)
      need_value "$1" "${2:-}"; QC_PATCH_COUNT="$2"; shift 2 ;;
    --qc-patch-size|--qc_patch_size)
      need_value "$1" "${2:-}"; QC_PATCH_SIZE="$2"; shift 2 ;;
    --run-cells-stage|--run_cells_stage)
      RUN_CELLS_STAGE="$(read_bool_or_true "${2:-}")"; shift "$(bool_shift_count "${2:-}")" ;;
    --amp)
      AMP="$(read_bool_or_true "${2:-}")"; shift "$(bool_shift_count "${2:-}")" ;;
    --log-level|--log_level)
      need_value "$1" "${2:-}"; LOG_LEVEL="$2"; shift 2 ;;
    --same-env-only|--same_env_only)
      SAME_ENV_ONLY="$(read_bool_or_true "${2:-}")"; shift "$(bool_shift_count "${2:-}")" ;;
    --process-debug|--process_debug)
      PROCESS_DEBUG="$(read_bool_or_true "${2:-}")"; shift "$(bool_shift_count "${2:-}")" ;;
    --export-levels|--export_levels)
      need_value "$1" "${2:-}"; EXPORT_LEVELS="$2"; shift 2 ;;
    --raw-extensions|--raw_extensions)
      need_value "$1" "${2:-}"; RAW_EXTENSIONS="$2"; shift 2 ;;
    --run-id)
      need_value "$1" "${2:-}"; RUN_ID="$2"; shift 2 ;;
    --no-report)
      WITH_REPORT="false"; shift ;;
    --no-trace)
      WITH_TRACE="false"; shift ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      fail "Unknown option: $1" ;;
  esac
done

[[ -n "${INPUT_DIR}" ]] || { usage >&2; fail "--input-dir is required"; }
[[ -d "${INPUT_DIR}" ]] || fail "Input directory does not exist: ${INPUT_DIR}"

if [[ -z "${OUTPUT_ROOT}" ]]; then
  OUTPUT_ROOT="${INPUT_DIR}/AI_RESULTS_LAZY_HISTOPLUS"
fi
mkdir -p "${OUTPUT_ROOT}"

case "${PROFILE}" in
  auto)
    if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi >/dev/null 2>&1; then
      NF_PROFILE="docker_gpu"
    else
      NF_PROFILE="docker_cpu"
      DEVICE="cpu"
    fi
    ;;
  gpu|docker_gpu)
    NF_PROFILE="docker_gpu" ;;
  cpu|docker_cpu)
    NF_PROFILE="docker_cpu"
    DEVICE="cpu" ;;
  *)
    NF_PROFILE="${PROFILE}" ;;
esac

export HF_HOME
export HUGGINGFACE_HUB_CACHE
mkdir -p "${HF_HOME}" "${HUGGINGFACE_HUB_CACHE}"

if [[ -z "${HF_TOKEN:-}" && -f "${HF_TOKEN_FILE}" ]]; then
  export HF_TOKEN="$(tr -d '\r\n' < "${HF_TOKEN_FILE}")"
fi

if [[ -z "${DOCKER_RUN_OPTIONS}" ]]; then
  DOCKER_RUN_OPTIONS="-u $(id -u):$(id -g) -v ${STORAGE_ROOT}:${STORAGE_ROOT} -v ${INPUT_DIR}:${INPUT_DIR} -v ${OUTPUT_ROOT}:${OUTPUT_ROOT} -v ${HF_HOME}:${HF_HOME} -e HF_TOKEN -e HF_HOME -e HUGGINGFACE_HUB_CACHE"
fi

NF_ARGS=(
  run "${PIPELINE_DIR}"
  -profile "${NF_PROFILE}"
  --container_image "${CONTAINER_IMAGE}"
  --docker_run_options "${DOCKER_RUN_OPTIONS}"
  --target_folder "${INPUT_DIR}"
  --output_root "${OUTPUT_ROOT}"
  --include "${INCLUDE}"
  --mpp "${MPP}"
  --tile_px "${TILE_PX}"
  --device "${DEVICE}"
  --celltypes_batch_size "${CELLTYPES_BATCH_SIZE}"
  --cells_batch_size "${CELLS_BATCH_SIZE}"
  --num_workers "${NUM_WORKERS}"
  --cpus "${CPUS}"
  --memory "${MEMORY}"
  --time "${TIME_LIMIT}"
  --convert_to_pyramidal "${CONVERT_TO_PYRAMIDAL}"
  --pyramidal_compression "${PYRAMIDAL_COMPRESSION}"
  --pyramidal_jpeg_q "${PYRAMIDAL_JPEG_Q}"
  --resume "${PIPELINE_RESUME}"
  --overwrite "${OVERWRITE}"
  --overwrite_export "${OVERWRITE_EXPORT}"
  --dry_run "${DRY_RUN}"
  --scan_only "${SCAN_ONLY}"
  --auto_export_missing "${AUTO_EXPORT_MISSING}"
  --no_progress "${NO_PROGRESS}"
  --structure_max_depth "${STRUCTURE_MAX_DEPTH}"
  --export_qupath "${EXPORT_QUPATH}"
  --qc_patch_count "${QC_PATCH_COUNT}"
  --qc_patch_size "${QC_PATCH_SIZE}"
  --run_cells_stage "${RUN_CELLS_STAGE}"
  --amp "${AMP}"
  --log_level "${LOG_LEVEL}"
  --same_env_only "${SAME_ENV_ONLY}"
  --process_debug "${PROCESS_DEBUG}"
  --export_levels "${EXPORT_LEVELS}"
  --export_tile "${EXPORT_TILE}"
  --export_compression "${EXPORT_COMPRESSION}"
  --export_compression_level "${EXPORT_COMPRESSION_LEVEL}"
  --raw_extensions "${RAW_EXTENSIONS}"
  --overlap "${OVERLAP}"
  --background_fraction "${BACKGROUND_FRACTION}"
  --ops_level "${OPS_LEVEL}"
  --tissue_level "${TISSUE_LEVEL}"
  --thumbnail_size "${THUMBNAIL_SIZE}"
  --pyramidal_tile "${PYRAMIDAL_TILE}"
  --cells_model "${CELLS_MODEL}"
  --histoplus_magnification "${HISTOPLUS_MAGNIFICATION}"
  --histoplus_repo_id "${HISTOPLUS_REPO_ID}"
  --zoom_size "${ZOOM_SIZE}"
  --overlay_alpha "${OVERLAY_ALPHA}"
  --figure_dpi "${FIGURE_DPI}"
  --zoom_max_polygons "${ZOOM_MAX_POLYGONS}"
  --qc_min_distance_factor "${QC_MIN_DISTANCE_FACTOR}"
)

if [[ -n "${EXCLUDE}" ]]; then
  NF_ARGS+=(--exclude "${EXCLUDE}")
fi

if [[ "${WITH_REPORT}" == "true" ]]; then
  NF_ARGS+=(-with-report "${OUTPUT_ROOT}/nextflow_report_${RUN_ID}.html")
fi
if [[ "${WITH_TRACE}" == "true" ]]; then
  NF_ARGS+=(-with-trace "${OUTPUT_ROOT}/nextflow_trace_${RUN_ID}.txt")
fi

NF_ARGS+=(-ansi-log false)

if [[ "${NEXTFLOW_RESUME}" == "true" ]]; then
  NF_ARGS+=(-resume)
fi

printf '[run] Nextflow profile: %s\n' "${NF_PROFILE}"
printf '[run] Container image:   %s\n' "${CONTAINER_IMAGE}"
printf '[run] Output root:       %s\n' "${OUTPUT_ROOT}"
[[ "${WITH_REPORT}" == "true" ]] && printf '[run] Report file:       %s\n' "${OUTPUT_ROOT}/nextflow_report_${RUN_ID}.html"
[[ "${WITH_TRACE}" == "true" ]] && printf '[run] Trace file:        %s\n' "${OUTPUT_ROOT}/nextflow_trace_${RUN_ID}.txt"

if command -v nextflow >/dev/null 2>&1; then
  NEXTFLOW_BIN="$(command -v nextflow)"
elif [[ -x "${HOME}/.local/bin/nextflow" ]]; then
  NEXTFLOW_BIN="${HOME}/.local/bin/nextflow"
else
  fail "Nextflow is not in PATH. Run ./setup_server.sh --install or add ~/.local/bin to PATH."
fi

exec "${NEXTFLOW_BIN}" "${NF_ARGS[@]}"
