import cdsapi
import os
from datetime import datetime, timedelta
import argparse


def _env_overwrite() -> bool:
    return os.environ.get("IHT_OVERWRITE", "0") in ("1", "true", "TRUE", "yes", "YES")


def _grib_valid(path: str) -> bool:
    if not (os.path.isfile(path) and os.path.getsize(path) > 1000):
        return False
    try:
        with open(path, "rb") as fh:
            return fh.read(4) == b"GRIB"
    except OSError:
        return False


parser = argparse.ArgumentParser(description="Download ERA5 waves for a date range")
parser.add_argument("start_date", help="Start date in YYYYMMDD format")
parser.add_argument("end_date", help="End date in YYYYMMDD format")
parser.add_argument(
    "--overwrite",
    action="store_true",
    help="Force re-download even if valid GRIB already exists",
)
args = parser.parse_args()

start_date = datetime.strptime(args.start_date, "%Y%m%d")
end_date = datetime.strptime(args.end_date, "%Y%m%d")
overwrite = args.overwrite or _env_overwrite()

print("Start:", start_date)
print("End:", end_date)
print(f"overwrite={overwrite}")

dataset = "reanalysis-era5-single-levels"
variables = [
    "significant_height_of_combined_wind_waves_and_swell",
    "mean_wave_period",
    "mean_wave_direction",
    "wave_spectral_directional_width",
]
area = [15.5, 89.5, -15.5, 145.5]

client = None
current_date = start_date
while current_date <= end_date:
    next_day = current_date + timedelta(days=1)
    day1_times = [f"{hour:02d}:00" for hour in range(12, 24)]
    day2_times = [f"{hour:02d}:00" for hour in range(0, 14)]

    folder_name = (
        f"{os.environ.get('CAWO_INPUT')}/era5_waves/era5_{current_date.strftime('%Y%m%d')}"
    )
    os.makedirs(folder_name, exist_ok=True)
    part1 = f"{folder_name}/era5_waves_part1.grib"
    part2 = f"{folder_name}/era5_waves_part2.grib"

    if not overwrite and _grib_valid(part1) and _grib_valid(part2):
        print(f"[skip] {folder_name} (valid GRIB; pass --overwrite to re-download)")
        current_date += timedelta(days=1)
        continue

    if client is None:
        client = cdsapi.Client()

    if overwrite or not _grib_valid(part1):
        request_day1 = {
            "product_type": "reanalysis",
            "variable": variables,
            "year": str(current_date.year),
            "month": f"{current_date.month:02d}",
            "day": f"{current_date.day:02d}",
            "time": day1_times,
            "data_format": "grib",
            "area": area,
        }
        print(f"Downloading {part1}")
        import pprint
        pprint.pprint(request_day1)
        client.retrieve(dataset, request_day1).download(part1)
    else:
        print(f"[skip] {part1}")

    if overwrite or not _grib_valid(part2):
        request_day2 = {
            "product_type": "reanalysis",
            "variable": variables,
            "year": str(next_day.year),
            "month": f"{next_day.month:02d}",
            "day": f"{next_day.day:02d}",
            "time": day2_times,
            "data_format": "grib",
            "area": area,
        }
        print(f"Downloading {part2}")
        client.retrieve(dataset, request_day2).download(part2)
    else:
        print(f"[skip] {part2}")

    current_date += timedelta(days=1)
