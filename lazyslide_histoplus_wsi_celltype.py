#!/usr/bin/env python3
"""LazySlide/HistoPLUS WSI worker used by the Nextflow pipeline."""
from __future__ import annotations

import argparse
import csv
import fnmatch
import inspect
import json
import logging
import os
import shutil
import subprocess
import sys
import time
import traceback
from pathlib import Path
from typing import Any, Callable, Iterable

SLIDE_EXTENSIONS = {
    ".svs", ".tif", ".tiff", ".ndpi", ".mrxs", ".vms", ".vmu", ".scn", ".bif",
    ".czi", ".vsi", ".isyntax", ".qptiff", ".ome.tif", ".ome.tiff", ".mds", ".mdsx",
}


def utc_now() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def setup_logging(level: str) -> None:
    logging.basicConfig(
        level=getattr(logging, level.upper(), logging.INFO),
        format="%(asctime)s %(levelname)s %(message)s",
    )


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Run LazySlide/HistoPLUS over WSI files.")
    p.add_argument("--target-folder", "--target_folder", "--input-dir", dest="target_folder")
    p.add_argument("--export-root", "--export_root")
    p.add_argument("--output-root", "--output_root", required=True)
    p.add_argument("--include", default="*")
    p.add_argument("--exclude", default="")
    p.add_argument("--raw-extensions", "--raw_extensions", nargs="*", default=[".mds", ".mdsx"])
    p.add_argument("--structure-max-depth", "--structure_max_depth", type=int, default=5)
    p.add_argument("--log-level", "--log_level", default="INFO")
    p.add_argument("--resume", action="store_true")
    p.add_argument("--overwrite", action="store_true")
    p.add_argument("--overwrite-export", "--overwrite_export", action="store_true")
    p.add_argument("--dry-run", "--dry_run", action="store_true")
    p.add_argument("--scan-only", "--scan_only", action="store_true")
    p.add_argument("--auto-export-missing", "--auto_export_missing", action="store_true")
    p.add_argument("--no-progress", "--no_progress", action="store_true")
    p.add_argument("--same-env-only", "--same_env_only", action="store_true")
    p.add_argument("--export-levels", "--export_levels", nargs="*", default=["0", "2"])
    p.add_argument("--export-tile", "--export_tile", type=int, default=1024)
    p.add_argument("--export-compression", "--export_compression", default="deflate")
    p.add_argument("--export-compression-level", "--export_compression_level", type=int, default=9)
    p.add_argument("--mpp", type=float, default=0.5)
    p.add_argument("--tile-px", "--tile_px", type=int, default=840)
    p.add_argument("--overlap", type=float, default=0.2)
    p.add_argument("--background-fraction", "--background_fraction", type=float, default=0.95)
    p.add_argument("--ops-level", "--ops_level", default="0")
    p.add_argument("--tissue-level", "--tissue_level", default="auto")
    p.add_argument("--thumbnail-size", "--thumbnail_size", type=int, default=2400)
    p.add_argument("--convert-to-pyramidal", "--convert_to_pyramidal", action="store_true")
    p.add_argument("--pyramidal-root", "--pyramidal_root", default="")
    p.add_argument("--pyramidal-tile", "--pyramidal_tile", type=int, default=512)
    p.add_argument("--pyramidal-compression", "--pyramidal_compression", default="lzw")
    p.add_argument("--pyramidal-jpeg-q", "--pyramidal_jpeg_q", type=int, default=90)
    p.add_argument("--device", default="cuda")
    p.add_argument("--num-workers", "--num_workers", type=int, default=0)
    p.add_argument("--cells-model", "--cells_model", default="instanseg")
    p.add_argument("--cells-batch-size", "--cells_batch_size", type=int, default=4)
    p.add_argument("--celltypes-batch-size", "--celltypes_batch_size", type=int, default=2)
    p.add_argument("--histoplus-magnification", "--histoplus_magnification", default="20x")
    p.add_argument("--histoplus-repo-id", "--histoplus_repo_id", default="Owkin-Bioptimus/histoplus")
    p.add_argument("--zoom-size", "--zoom_size", type=int, default=2000)
    p.add_argument("--overlay-alpha", "--overlay_alpha", type=float, default=0.55)
    p.add_argument("--figure-dpi", "--figure_dpi", type=int, default=300)
    p.add_argument("--zoom-max-polygons", "--zoom_max_polygons", type=int, default=0)
    p.add_argument("--export-qupath", "--export_qupath", action="store_true")
    p.add_argument("--qc-patch-count", "--qc_patch_count", type=int, default=0)
    p.add_argument("--qc-patch-size", "--qc_patch_size", type=int, default=1024)
    p.add_argument("--qc-min-distance-factor", "--qc_min_distance_factor", type=float, default=0.85)
    p.add_argument("--run-cells-stage", "--run_cells_stage", action="store_true")
    p.add_argument("--amp", action="store_true")
    args, unknown = p.parse_known_args(argv)
    args.unknown_args = unknown
    if not args.target_folder and not args.export_root:
        p.error("one of --target-folder/--input-dir or --export-root is required")
    return args


def allowed_extensions(raw_extensions: Iterable[str]) -> set[str]:
    exts = set(SLIDE_EXTENSIONS)
    for ext in raw_extensions:
        e = ext.lower()
        if not e.startswith("."):
            e = f".{e}"
        exts.add(e)
    return exts


def matches_ext(path: Path, exts: set[str]) -> bool:
    name = path.name.lower()
    return any(name.endswith(ext) for ext in exts)


def discover(root: Path, include: str, exclude: str, max_depth: int, raw_extensions: list[str]) -> list[dict[str, Any]]:
    exts = allowed_extensions(raw_extensions)
    rows: list[dict[str, Any]] = []
    root = root.resolve()
    for path in root.rglob("*"):
        if not path.is_file():
            continue
        rel = path.relative_to(root)
        if len(rel.parts) - 1 > max_depth:
            continue
        rel_s = rel.as_posix()
        if include and not (fnmatch.fnmatch(path.name, include) or fnmatch.fnmatch(rel_s, include)):
            continue
        if exclude and (fnmatch.fnmatch(path.name, exclude) or fnmatch.fnmatch(rel_s, exclude)):
            continue
        if not matches_ext(path, exts):
            continue
        st = path.stat()
        rows.append({
            "path": str(path),
            "relative_path": rel_s,
            "name": path.name,
            "stem": path.stem,
            "suffix": path.suffix.lower(),
            "size_bytes": st.st_size,
            "mtime": st.st_mtime,
        })
    return sorted(rows, key=lambda r: r["relative_path"])


def write_manifest(rows: list[dict[str, Any]], root: Path, output_root: Path, args: argparse.Namespace) -> None:
    output_root.mkdir(parents=True, exist_ok=True)
    csv_path = output_root / "scan_manifest.csv"
    json_path = output_root / "scan_manifest.json"
    fields = ["path", "relative_path", "name", "stem", "suffix", "size_bytes", "mtime"]
    with csv_path.open("w", newline="", encoding="utf-8") as fh:
        writer = csv.DictWriter(fh, fieldnames=fields)
        writer.writeheader()
        writer.writerows(rows)
    with json_path.open("w", encoding="utf-8") as fh:
        json.dump({
            "created_utc": utc_now(),
            "input_root": str(root),
            "output_root": str(output_root),
            "include": args.include,
            "exclude": args.exclude,
            "slide_count": len(rows),
            "slides": rows,
        }, fh, indent=2, ensure_ascii=False)
    logging.info("Wrote %s", csv_path)
    logging.info("Wrote %s", json_path)


def call_supported(func: Callable[..., Any], *args: Any, **kwargs: Any) -> Any:
    sig = inspect.signature(func)
    accepted = {k: v for k, v in kwargs.items() if k in sig.parameters}
    return func(*args, **accepted)


def convert_pyramidal(slide: Path, output_root: Path, args: argparse.Namespace) -> Path:
    if not args.convert_to_pyramidal:
        return slide
    out_root = Path(args.pyramidal_root) if args.pyramidal_root else output_root / "pyramidal"
    out_root.mkdir(parents=True, exist_ok=True)
    out = out_root / f"{slide.stem}.ome.tif"
    if out.exists() and args.resume and not args.overwrite:
        logging.info("Using existing pyramidal file: %s", out)
        return out
    try:
        import pyvips  # type: ignore
    except Exception:
        logging.warning("pyvips unavailable; continuing with original file: %s", slide)
        return slide
    logging.info("Converting to pyramidal TIFF: %s -> %s", slide, out)
    image = pyvips.Image.new_from_file(str(slide), access="sequential")
    kwargs: dict[str, Any] = {
        "tile": True,
        "tile_width": args.pyramidal_tile,
        "tile_height": args.pyramidal_tile,
        "pyramid": True,
        "bigtiff": True,
        "compression": args.pyramidal_compression,
    }
    if args.pyramidal_compression.lower() in {"jpeg", "jpg"}:
        kwargs["Q"] = args.pyramidal_jpeg_q
    image.tiffsave(str(out), **kwargs)
    return out


def save_wsi(wsi: Any, out_dir: Path, overwrite: bool) -> None:
    zarr = out_dir / "wsi.zarr"
    if zarr.exists() and overwrite:
        shutil.rmtree(zarr)
    for name in ("write", "write_zarr", "save"):
        method = getattr(wsi, name, None)
        if not method:
            continue
        try:
            call_supported(method, str(zarr), overwrite=overwrite)
            logging.info("Saved WSI object: %s", zarr)
            return
        except Exception as exc:
            logging.debug("Save method %s failed: %s", name, exc)
    logging.warning("Could not save WSI object; continuing")


def run_lazyslide(slide: Path, out_dir: Path, args: argparse.Namespace) -> None:
    import lazyslide as zs  # type: ignore
    from wsidata import open_wsi  # type: ignore
    wsi = open_wsi(str(slide))
    call_supported(zs.pp.find_tissues, wsi)
    call_supported(
        zs.pp.tile_tissues,
        wsi,
        args.tile_px,
        tile_px=args.tile_px,
        overlap=args.overlap,
        background_fraction=args.background_fraction,
        mpp=args.mpp,
    )
    if args.run_cells_stage:
        call_supported(
            zs.seg.cells,
            wsi,
            model=args.cells_model,
            batch_size=args.cells_batch_size,
            device=args.device,
            num_workers=args.num_workers,
            mixed_precision=args.amp,
        )
        call_supported(
            zs.seg.cell_types,
            wsi,
            model="histoplus",
            batch_size=args.celltypes_batch_size,
            device=args.device,
            num_workers=args.num_workers,
            mixed_precision=args.amp,
        )
    save_wsi(wsi, out_dir, args.overwrite)
    if args.export_qupath and hasattr(zs, "io") and hasattr(zs.io, "export_annotations"):
        qout = out_dir / "qupath"
        qout.mkdir(exist_ok=True)
        call_supported(zs.io.export_annotations, wsi, output=str(qout), output_dir=str(qout), overwrite=args.overwrite_export or args.overwrite)


def run_histoplus_cli(slide: Path, out_dir: Path, args: argparse.Namespace) -> None:
    exe = shutil.which("histoplus")
    if not exe:
        raise RuntimeError("histoplus CLI is not installed")
    cmd = [exe, "--slides", str(slide), "--export_dir", str(out_dir), "--batch_size", str(args.celltypes_batch_size)]
    logging.info("Running HistoPLUS CLI: %s", " ".join(cmd))
    subprocess.run(cmd, check=True)


def process_one(row: dict[str, Any], output_root: Path, args: argparse.Namespace) -> dict[str, Any]:
    slide = Path(row["path"])
    out_dir = output_root / row["stem"]
    out_dir.mkdir(parents=True, exist_ok=True)
    done = out_dir / "status.done.json"
    status = {
        "slide": str(slide),
        "output_dir": str(out_dir),
        "started_at": utc_now(),
        "finished_at": "",
        "status": "running",
        "message": "",
    }
    if done.exists() and args.resume and not args.overwrite:
        status.update(status="skipped", finished_at=utc_now(), message="Existing completed status found and --resume enabled")
        return status
    try:
        if args.dry_run:
            status["message"] = "Dry run: no model executed"
        else:
            used = convert_pyramidal(slide, output_root, args)
            try:
                run_lazyslide(used, out_dir, args)
            except Exception as exc:
                logging.warning("LazySlide path failed for %s: %s", slide, exc)
                if args.run_cells_stage:
                    run_histoplus_cli(used, out_dir, args)
                else:
                    raise
            status["message"] = "Processed successfully"
        status.update(status="completed", finished_at=utc_now())
        done.write_text(json.dumps(status, indent=2, ensure_ascii=False), encoding="utf-8")
    except Exception as exc:
        status.update(status="failed", finished_at=utc_now(), message=str(exc))
        (out_dir / "error.txt").write_text(traceback.format_exc(), encoding="utf-8")
        (out_dir / "status.failed.json").write_text(json.dumps(status, indent=2, ensure_ascii=False), encoding="utf-8")
    return status


def write_summary(statuses: list[dict[str, Any]], output_root: Path) -> None:
    csv_path = output_root / "run_summary.csv"
    json_path = output_root / "run_summary.json"
    fields = ["slide", "output_dir", "started_at", "finished_at", "status", "message"]
    with csv_path.open("w", newline="", encoding="utf-8") as fh:
        writer = csv.DictWriter(fh, fieldnames=fields)
        writer.writeheader()
        writer.writerows(statuses)
    json_path.write_text(json.dumps(statuses, indent=2, ensure_ascii=False), encoding="utf-8")


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    setup_logging(args.log_level)
    root = Path(args.export_root or args.target_folder).expanduser().resolve()
    output_root = Path(args.output_root).expanduser().resolve()
    if not root.exists():
        logging.error("Input root does not exist: %s", root)
        return 2
    output_root.mkdir(parents=True, exist_ok=True)
    rows = discover(root, args.include, args.exclude, args.structure_max_depth, args.raw_extensions)
    write_manifest(rows, root, output_root, args)
    logging.info("Found %d candidate slides", len(rows))
    if args.scan_only:
        logging.info("Scan-only completed")
        return 0
    if not rows:
        logging.warning("No slide files matched the filters")
        return 0
    statuses = [process_one(row, output_root, args) for row in rows]
    write_summary(statuses, output_root)
    return 1 if any(s["status"] == "failed" for s in statuses) else 0


if __name__ == "__main__":
    raise SystemExit(main())
