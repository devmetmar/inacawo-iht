#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Download GLORYS reanalysis (daily) via Copernicus Marine."""
import os
import subprocess
import sys
from datetime import datetime, timedelta
import argparse

import copernicusmarine

parser = argparse.ArgumentParser(description="Download GLORYS reanalysis for a date range")
parser.add_argument("start_date", help="Start date in YYYYMMDD format")
parser.add_argument("end_date", help="End date in YYYYMMDD format")
parser.add_argument(
    "--overwrite",
    action="store_true",
    help="Force re-download even if valid NetCDF already exists",
)
args = parser.parse_args()

start_date = datetime.strptime(args.start_date, "%Y%m%d")
end_date = datetime.strptime(args.end_date, "%Y%m%d")

overwrite = args.overwrite or os.environ.get("IHT_OVERWRITE", "0") in (
    "1",
    "true",
    "TRUE",
    "yes",
    "YES",
)

cawo = os.environ.get("CAWO_INPUT")
if not cawo:
    print("ERROR: CAWO_INPUT is not set", file=sys.stderr)
    sys.exit(1)
out_dir = os.path.join(cawo, "mercator")
os.makedirs(out_dir, exist_ok=True)

# Prefer env credentials (setup_env / vault); do not hardcode.
username = (
    os.environ.get("COPERNICUSMARINE_SERVICE_USERNAME")
    or os.environ.get("CMEMS_USERNAME")
    or None
)
password = (
    os.environ.get("COPERNICUSMARINE_SERVICE_PASSWORD")
    or os.environ.get("CMEMS_PASSWORD")
    or None
)


def _nc_valid(path: str) -> bool:
    if not (os.path.isfile(path) and os.path.getsize(path) > 0):
        return False
    try:
        r = subprocess.run(
            ["ncdump", "-h", path],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )
        return r.returncode == 0
    except FileNotFoundError:
        return False


print("Start:", start_date)
print("End:", end_date)
print(f"overwrite={overwrite}  out_dir={out_dir}")

current_date = start_date
while current_date <= end_date:
    current_date_str = current_date.strftime("%Y-%m-%dT%H:%M:%S")
    out_name = f"GLORYS_Reanalysis_LO_{current_date_str}.nc"
    out_path = os.path.join(out_dir, out_name)

    if not overwrite and _nc_valid(out_path):
        print(f"[skip] {out_path} (valid NetCDF; pass --overwrite to re-download)")
        current_date += timedelta(days=1)
        continue

    kwargs = dict(
        dataset_id="cmems_mod_glo_phy_my_0.083deg_P1D-m",
        variables=["so", "thetao", "uo", "vo", "zos"],
        minimum_longitude=89.5,
        maximum_longitude=145.5,
        minimum_latitude=-15.5,
        maximum_latitude=15.5,
        start_datetime=current_date_str,
        end_datetime=current_date_str,
        minimum_depth=0.494,
        maximum_depth=5727.9169921875,
        output_filename=out_name,
        output_directory=out_dir,
        force_download=True if overwrite else False,
    )
    if username and password:
        kwargs["username"] = username
        kwargs["password"] = password

    copernicusmarine.subset(**kwargs)
    current_date += timedelta(days=1)
