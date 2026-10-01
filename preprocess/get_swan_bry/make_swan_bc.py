#!/usr/bin/env python3
import numpy as np
import xarray as xr
import os
from datetime import datetime, timedelta

# ===== CONFIG =====
indir_base = os.environ.get("SCRATCH_PREPROCESS")+"/"+"era5_waves"   # Base dir for GRIB files
outdir_base = os.environ.get("SCRATCH_PREPROCESS")+"/"+"swan_bcs"    # Base dir for output BC files
print(f"indir_base {indir_base}")
print(f"outdir_base {outdir_base}")
lon_idx_east = 111
lon_idx_west = 1
lat_idx_north = 1
lat_idx_south = 61
lat_range = range(1, 61)   # 60 points
lon_range = range(1, 111)  # 110 points
spread_value = 15.0
# ===================

def format_time(t):
    """Format time for TPAR file."""
    return np.datetime_as_string(t, unit='m').replace('-', '').replace(':', '').replace('T', '.')[:13]

def write_tpar(fname, times, hs, tp, direction, spread):
    """Write one TPAR boundary file."""
    with open(fname, 'w') as f:
        f.write("TPAR\n")
        for t, h, p, d in zip(times, hs, tp, direction):
            f.write(f"{format_time(t):>13} {h:10.4f} {p:10.4f} {d:10.4f}   {spread:.1f}\n")

def process_one_day(start_date):
    """Process one day: start_date 12h → next_date 12h."""
    end_date = start_date + timedelta(days=1)

    # Input/output paths
    date_folder = "era5_" + start_date.strftime("%Y%m%d")
    inpath = os.path.join(indir_base, date_folder, "*.grib")
    outdir = os.path.join(outdir_base, date_folder)
    os.makedirs(outdir, exist_ok=True)

    # Load dataset
    ds = xr.open_mfdataset(inpath, engine="cfgrib")
    ds = ds.sel(time=slice(f"{start_date:%Y-%m-%d} 12:00:00", f"{end_date:%Y-%m-%d} 12:00:00"))
    ds = ds.isel(time=slice(0, None, 6))  # every 6 steps (6h)

    swh = ds.swh.values
    mwp = ds.mwp.values
    mwd = ds.mwd.values
    times = ds.time.values

    # EAST
    for i, j in enumerate(lat_range):
        write_tpar(os.path.join(outdir, f"BCEast_{i+1}.txt"), times, swh[:, j, lon_idx_east], mwp[:, j, lon_idx_east], mwd[:, j, lon_idx_east], spread_value)

    # NORTH
    for i, j in enumerate(lon_range):
        write_tpar(os.path.join(outdir, f"BCNorth_{i+1}.txt"), times, swh[:, lat_idx_north, j], mwp[:, lat_idx_north, j], mwd[:, lat_idx_north, j], spread_value)

    # WEST
    for i, j in enumerate(lat_range):
        write_tpar(os.path.join(outdir, f"BCWest_{i+1}.txt"), times, swh[:, j, lon_idx_west], mwp[:, j, lon_idx_west], mwd[:, j, lon_idx_west], spread_value)

    # SOUTH
    for i, j in enumerate(lon_range):
        write_tpar(os.path.join(outdir, f"BCSouth_{i+1}.txt"), times, swh[:, lat_idx_south, j], mwp[:, lat_idx_south, j], mwd[:, lat_idx_south, j], spread_value)

    print(f"✅ Processed {date_folder}")

if __name__ == "__main__":

    import argparse

    parser = argparse.ArgumentParser(description="Process data in a date range")

    parser.add_argument("start_date", help="Start date in YYYYMMDD format")
    parser.add_argument("end_date", help="End date in YYYYMMDD format")

    args = parser.parse_args()

    start_date = datetime.strptime(args.start_date, "%Y%m%d")
    end_date = datetime.strptime(args.end_date, "%Y%m%d")

    print(f"start_date {start_date}")
    print(f"end_date {end_date}")

    curr = start_date
    while curr <= end_date:
        print(f"Processing {curr} ...")
        process_one_day(curr)
        curr += timedelta(days=1)

