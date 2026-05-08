nextflow.enable.dsl = 2

def shellQuote(value) {
    if (value == null) return "''"
    return "'" + value.toString().replace("'", "'\"'\"'") + "'"
}

def asBool(value) {
    if (value == null) return false
    if (value instanceof Boolean) return value
    def s = value.toString().trim().toLowerCase()
    return s in ['true', 't', 'yes', 'y', '1', 'on']
}

def hasText(value) {
    if (value == null) return false
    if (value instanceof Boolean) return false
    def s = value.toString().trim()
    if (!s) return false
    if (s.toLowerCase() in ['false', 'null', 'none']) return false
    return true
}

def optValue(cliName, value) {
    if (!hasText(value)) return ''
    return "${cliName} ${shellQuote(value)}"
}

def optFlag(cliName, value) {
    return asBool(value) ? cliName : ''
}

def optList(cliName, value) {
    if (value == null) return ''
    def items
    if (value instanceof Collection) {
        items = value.collect { it.toString().trim() }
    }
    else {
        items = value.toString().split(/[\s,]+/).collect { it.trim() }
    }
    items = items.findAll { it }
    if (!items) return ''
    return "${cliName} " + items.collect { shellQuote(it) }.join(' ')
}

params.container_image = params.container_image ?: 'carlosfarkas/lazyslide-histoplus:latest'
params.cpus = params.cpus ?: 8
params.memory = params.memory ?: '32 GB'
params.time = params.time ?: '72h'
params.include = params.include ?: '*'
params.output_root = params.output_root ?: null
params.target_folder = params.target_folder ?: params.input_dir ?: null
params.export_root = params.export_root ?: null
params.exclude = params.exclude ?: ''

process RUN_LAZYSLIDE {
    tag { params.target_folder ?: params.export_root ?: 'lazyslide-input' }

    container "${params.container_image}"
    cpus { params.cpus as int }
    memory { params.memory }
    time { params.time }
    errorStrategy 'terminate'

    output:
    path 'run.done'

    script:
    if (!params.target_folder && !params.export_root) {
        error "Missing required parameter: --target_folder/--input_dir or --export_root"
    }

    def inputRoot = params.target_folder ?: params.export_root
    def outputRoot = params.output_root ?: "${inputRoot}/AI_RESULTS_LAZY_HISTOPLUS"

    def cli = [
        optValue('--target-folder', params.target_folder),
        optValue('--export-root', params.export_root),
        optValue('--output-root', outputRoot),
        optValue('--include', params.include ?: '*'),
        hasText(params.exclude) ? optValue('--exclude', params.exclude) : '',
        optValue('--log-level', params.log_level ?: 'INFO'),
        optFlag('--resume', params.resume),
        optFlag('--overwrite', params.overwrite),
        optFlag('--overwrite-export', params.overwrite_export),
        optFlag('--dry-run', params.dry_run),
        optFlag('--scan-only', params.scan_only),
        optFlag('--auto-export-missing', params.auto_export_missing),
        optFlag('--no-progress', params.no_progress),
        optValue('--structure-max-depth', params.structure_max_depth ?: 5),
        optFlag('--same-env-only', params.same_env_only),
        optList('--export-levels', params.export_levels ?: '0 2'),
        optValue('--export-tile', params.export_tile ?: 1024),
        optValue('--export-compression', params.export_compression ?: 'deflate'),
        optValue('--export-compression-level', params.export_compression_level ?: 9),
        optList('--raw-extensions', params.raw_extensions ?: '.mds .mdsx'),
        optValue('--mpp', params.mpp ?: 0.5),
        optValue('--tile-px', params.tile_px ?: 840),
        optValue('--overlap', params.overlap ?: 0.2),
        optValue('--background-fraction', params.background_fraction ?: 0.95),
        optValue('--ops-level', params.ops_level ?: 0),
        optValue('--tissue-level', params.tissue_level ?: 'auto'),
        optValue('--thumbnail-size', params.thumbnail_size ?: 2400),
        optFlag('--convert-to-pyramidal', params.convert_to_pyramidal),
        optValue('--pyramidal-tile', params.pyramidal_tile ?: 512),
        optValue('--pyramidal-compression', params.pyramidal_compression ?: 'lzw'),
        optValue('--pyramidal-jpeg-q', params.pyramidal_jpeg_q ?: 90),
        optValue('--device', params.device ?: 'cuda'),
        optValue('--num-workers', params.num_workers ?: 0),
        optValue('--cells-model', params.cells_model ?: 'instanseg'),
        optValue('--cells-batch-size', params.cells_batch_size ?: 4),
        optValue('--celltypes-batch-size', params.celltypes_batch_size ?: 2),
        optValue('--histoplus-magnification', params.histoplus_magnification ?: '20x'),
        optValue('--histoplus-repo-id', params.histoplus_repo_id ?: 'Owkin-Bioptimus/histoplus'),
        optValue('--zoom-size', params.zoom_size ?: 2000),
        optValue('--overlay-alpha', params.overlay_alpha ?: 0.55),
        optValue('--figure-dpi', params.figure_dpi ?: 300),
        optValue('--zoom-max-polygons', params.zoom_max_polygons ?: 0),
        optFlag('--export-qupath', params.export_qupath),
        optValue('--qc-patch-count', params.qc_patch_count ?: 0),
        optValue('--qc-patch-size', params.qc_patch_size ?: 1024),
        optValue('--qc-min-distance-factor', params.qc_min_distance_factor ?: 0.85),
        optFlag('--run-cells-stage', params.run_cells_stage),
        optFlag('--amp', params.amp)
    ].findAll { it != null && it.toString().trim() }.join(' \\\n        ')

    """
    set -Eeuo pipefail

    python /opt/lazyslide/lazyslide_histoplus_wsi_celltype.py \\
        ${cli}

    printf 'ok\n' > run.done
    """
}

workflow {
    RUN_LAZYSLIDE()
}
