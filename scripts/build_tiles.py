#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = ["rasterio==1.4.4", "Pillow==12.1.1"]
# ///
"""Generate the bundled XYZ tile archive from Stanford's original ID_341.tif."""

import argparse
import hashlib
import io
import math
from pathlib import Path
import sqlite3
import tempfile

from PIL import Image
import numpy as np
import rasterio
from rasterio.enums import Resampling
from rasterio.transform import from_origin
from rasterio.vrt import WarpedVRT
from rasterio.warp import transform_bounds
from rasterio.windows import Window

ARCHIVE_SHA1 = "6bf543553be12263cf8ce6e1a1e7a1f88a17cab6"
PROJECTION = "EPSG:3857"
HALF_WORLD = math.pi * 6_378_137
TILE_SIZE = 256
ZOOMS = range(10, 18)
# Local display correction for this sheet only (Web Mercator metres, east/north).
# Keep source coordinates intact; see README.md for the three reference checks.
DISPLAY_OFFSETS = {"source": (0, 0), "mainland": (485, -300)}

# Outer edge of the paper measured on an 800 × 630 overview of this exact scan.
# Inset slightly so the black scanner bed does not show through at the edges.
SHEET_EDGE = ((2.0, 149.8), (682.0, 2.4), (797.3, 481.2), (118.9, 627.2))


def pixel_cutline(width: int, height: int) -> str:
    corners = (*SHEET_EDGE, SHEET_EDGE[0])
    coordinates = ", ".join(f"{x * width / 800:.4f} {y * height / 630:.4f}" for x, y in corners)
    return f"POLYGON (({coordinates}))"


def build(source: Path, output: Path, profile: str) -> None:
    dx, dy = DISPLAY_OFFSETS[profile]
    with source.open("rb") as file:
        if hashlib.file_digest(file, "sha1").hexdigest() != ARCHIVE_SHA1:
            raise ValueError("Input is not Stanford's original ID_341.tif.")

    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=output.parent) as temp:
        database = Path(temp) / output.name
        with rasterio.Env(GDAL_CACHEMAX=128_000_000), rasterio.open(source) as src, sqlite3.connect(database) as db:
            db.execute("""CREATE TABLE tiles (
                z INTEGER NOT NULL, x INTEGER NOT NULL, y INTEGER NOT NULL, data BLOB NOT NULL,
                PRIMARY KEY (z, x, y)
            ) WITHOUT ROWID""")
            db.execute("PRAGMA user_version = 1")
            left, bottom, right, top = transform_bounds(src.crs, PROJECTION, *src.bounds)
            left, bottom, right, top = left + dx, bottom + dy, right + dx, top + dy
            for zoom in ZOOMS:
                span = 2 * HALF_WORLD / (1 << zoom)
                x0, x1 = (math.floor((x + HALF_WORLD) / span) for x in (left, right))
                y0, y1 = (math.floor((HALF_WORLD - y) / span) for y in (top, bottom))
                resolution = span / TILE_SIZE
                # Sample the original reprojection at (display x - dx, display y - dy).
                grid = from_origin(x0 * span - HALF_WORLD - dx, HALF_WORLD - y0 * span - dy,
                                   resolution, resolution)
                with WarpedVRT(
                    src, crs=PROJECTION, transform=grid,
                    width=(x1 - x0 + 1) * TILE_SIZE, height=(y1 - y0 + 1) * TILE_SIZE,
                    src_alpha=4, dst_alpha=4, resampling=Resampling.bilinear,
                    CUTLINE=pixel_cutline(src.width, src.height),
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
                            image = Image.fromarray(np.moveaxis(pixels, 0, -1))
                            with io.BytesIO() as buffer:
                                if alpha.min() == 255:
                                    image.convert("RGB").save(buffer, format="JPEG", quality=85, subsampling=1)
                                else:
                                    image.save(buffer, format="PNG", optimize=True)
                                db.execute("INSERT INTO tiles VALUES (?, ?, ?, ?)", (zoom, x, y, buffer.getvalue()))
                            count += 1
                if not count:
                    raise RuntimeError(f"No tile data at zoom {zoom}")
                print(f"Zoom {zoom}: {count} tiles", flush=True)
            db.commit()
            db.execute("VACUUM")
        database.replace(output)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--profile", choices=DISPLAY_OFFSETS, default="source")
    args = parser.parse_args()
    build(args.source, args.output, args.profile)
