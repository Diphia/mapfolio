#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = ["rasterio==1.4.4", "Pillow==12.1.1", "numpy"]
# ///
"""Generate bundled XYZ SQLite tile archives from Allmaps-georeferenced public domain city plans."""

import argparse
import hashlib
import io
import json
import math
from pathlib import Path
import sqlite3
import tempfile

import numpy as np
from PIL import Image
import rasterio
from rasterio.enums import Resampling
from rasterio.transform import Affine, from_origin
from rasterio.vrt import WarpedVRT
from rasterio.windows import Window

Image.MAX_IMAGE_PIXELS = None

PROJECTION = "EPSG:3857"
HALF_WORLD = math.pi * 6_378_137
TILE_SIZE = 256
ZOOMS = range(10, 18)


def lonlat_to_merc(lon: float, lat: float) -> tuple[float, float]:
    x = lon * HALF_WORLD / 180.0
    y = math.log(math.tan((90.0 + lat) * math.pi / 360.0)) / (math.pi / 180.0)
    y = y * HALF_WORLD / 180.0
    return x, y


def merc_to_lonlat(x: float, y: float) -> tuple[float, float]:
    lon = x * 180.0 / HALF_WORLD
    lat = math.atan(math.sinh(y * math.pi / HALF_WORLD)) * 180.0 / math.pi
    return lon, lat


def fit_affine_from_gcps(gcps: list[tuple[float, float, float, float]]) -> Affine:
    """Fit a 1st-order affine transform mapping (px, py) -> EPSG:3857 (x, y)."""
    a_mat = np.array([[px, py, 1.0] for px, py, _, _ in gcps], dtype=np.float64)
    b_mat = np.array([lonlat_to_merc(lon, lat) for _, _, lon, lat in gcps], dtype=np.float64)
    coeffs, _, _, _ = np.linalg.lstsq(a_mat, b_mat, rcond=None)
    return Affine(
        coeffs[0, 0], coeffs[1, 0], coeffs[2, 0],
        coeffs[0, 1], coeffs[1, 1], coeffs[2, 1],
    )


def pixel_cutline(width: int, height: int, sheet_edge: list[tuple[float, float]]) -> str:
    ov_w = 800.0
    ov_h = round(800.0 * height / width)
    corners = (*sheet_edge, sheet_edge[0])
    coordinates = ", ".join(f"{x * width / ov_w:.4f} {y * height / ov_h:.4f}" for x, y in corners)
    return f"POLYGON (({coordinates}))"


def load_spec(spec_path: Path, map_id: str) -> dict:
    specs = json.loads(spec_path.read_text(encoding="utf-8"))
    if map_id not in specs:
        raise KeyError(f"Unknown map_id '{map_id}'. Available: {', '.join(specs)}")
    return specs[map_id]


def build(source: Path, output: Path, spec_path: Path, map_id: str, profile: str) -> None:
    spec = load_spec(spec_path, map_id)
    offsets = spec["display_offsets"]
    if profile not in offsets:
        raise ValueError(f"Profile '{profile}' not defined for '{map_id}'. Choices: {list(offsets)}")
    dx, dy = offsets[profile]

    with source.open("rb") as file:
        digest = hashlib.file_digest(file, "sha1").hexdigest()
        if digest != spec["sha1"]:
            raise ValueError(f"SHA1 mismatch for {source}: got {digest}, expected {spec['sha1']}")

    gcps = [(g[0], g[1], g[2], g[3]) for g in spec["gcps"]]
    aff = fit_affine_from_gcps(gcps)

    img = Image.open(source).convert("RGB")
    width, height = img.size
    if (width, height) != (spec["width"], spec["height"]):
        raise ValueError(f"Unexpected dimensions {(width, height)} != {(spec['width'], spec['height'])}")

    corners_merc = [aff * pt for pt in [(0, 0), (width, 0), (width, height), (0, height)]]
    left = min(p[0] for p in corners_merc) + dx
    right = max(p[0] for p in corners_merc) + dx
    bottom = min(p[1] for p in corners_merc) + dy
    top = max(p[1] for p in corners_merc) + dy

    nw = merc_to_lonlat(left - dx, top - dy)
    se = merc_to_lonlat(right - dx, bottom - dy)
    print(f"[{map_id}:{profile}] Source bounds WGS-84 NW=({nw[1]:.6f}, {nw[0]:.6f}) SE=({se[1]:.6f}, {se[0]:.6f})", flush=True)

    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=output.parent) as temp:
        temp_dir = Path(temp)
        geotiff = temp_dir / f"{map_id}.tif"
        rgb = np.asarray(img)
        rgba = np.empty((4, height, width), dtype=np.uint8)
        rgba[0:3] = np.moveaxis(rgb, -1, 0)
        rgba[3] = 255
        with rasterio.open(
            geotiff, "w",
            driver="GTiff",
            height=height,
            width=width,
            count=4,
            dtype=np.uint8,
            crs=PROJECTION,
            transform=aff,
            tiled=True,
            blockxsize=256,
            blockysize=256,
            compress="deflate",
        ) as dst:
            dst.write(rgba)

        database = temp_dir / output.name
        cutline = pixel_cutline(width, height, [tuple(p) for p in spec["sheet_edge"]])
        with rasterio.Env(GDAL_CACHEMAX=256_000_000), rasterio.open(geotiff) as src, sqlite3.connect(database) as db:
            db.execute("""CREATE TABLE tiles (
                z INTEGER NOT NULL, x INTEGER NOT NULL, y INTEGER NOT NULL, data BLOB NOT NULL,
                PRIMARY KEY (z, x, y)
            ) WITHOUT ROWID""")
            db.execute("PRAGMA user_version = 1")
            for zoom in ZOOMS:
                span = 2 * HALF_WORLD / (1 << zoom)
                x0, x1 = (math.floor((x + HALF_WORLD) / span) for x in (left, right))
                y0, y1 = (math.floor((HALF_WORLD - y) / span) for y in (top, bottom))
                resolution = span / TILE_SIZE
                grid = from_origin(x0 * span - HALF_WORLD - dx, HALF_WORLD - y0 * span - dy,
                                   resolution, resolution)
                with WarpedVRT(
                    src, crs=PROJECTION, transform=grid,
                    width=(x1 - x0 + 1) * TILE_SIZE, height=(y1 - y0 + 1) * TILE_SIZE,
                    src_alpha=4, dst_alpha=4, resampling=Resampling.bilinear,
                    CUTLINE=cutline,
                ) as vrt:
                    count = 0
                    for y in range(y0, y1 + 1):
                        for x in range(x0, x1 + 1):
                            pixels = vrt.read(window=Window(
                                (x - x0) * TILE_SIZE, (y - y0) * TILE_SIZE, TILE_SIZE, TILE_SIZE
                            ))
                            alpha = pixels[3]
                            if not alpha.any():
                                continue
                            tile_img = Image.fromarray(np.moveaxis(pixels, 0, -1))
                            with io.BytesIO() as buffer:
                                if alpha.min() == 255:
                                    tile_img.convert("RGB").save(buffer, format="JPEG", quality=85, subsampling=1)
                                else:
                                    tile_img.save(buffer, format="PNG", optimize=True)
                                db.execute("INSERT INTO tiles VALUES (?, ?, ?, ?)", (zoom, x, y, buffer.getvalue()))
                            count += 1
                if not count:
                    raise RuntimeError(f"No tile data at zoom {zoom}")
                print(f"  Zoom {zoom}: {count} tiles", flush=True)
            db.commit()
            db.execute("VACUUM")
        database.replace(output)
        print(f"Wrote {output} ({output.stat().st_size / (1024 * 1024):.1f} MB)", flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("map_id")
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--profile", default="source")
    parser.add_argument("--specs", type=Path, default=Path(__file__).with_name("allmaps_specs.json"))
    args = parser.parse_args()
    build(args.source, args.output, args.specs, args.map_id, args.profile)
