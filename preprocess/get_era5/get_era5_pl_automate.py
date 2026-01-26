import cdsapi
import os
from datetime import datetime, timedelta
import argparse

parser = argparse.ArgumentParser(description="Process data in a date range")

parser.add_argument("start_date", help="Start date in YYYYMMDD format")
parser.add_argument("end_date", help="End date in YYYYMMDD format")

args = parser.parse_args()

start_date = datetime.strptime(args.start_date, "%Y%m%d")
end_date = datetime.strptime(args.end_date, "%Y%m%d")

print("Start:", start_date)
print("End:", end_date)

# Define constant parameters
dataset = "reanalysis-era5-pressure-levels"
pressure_levels = [
    "5", "7", "10", "20", "30", "50", "70", "100", "150", "200", "250", "300",
    "400", "500", "600", "700", "800", "850", "900", "925", "950", "1000"
]
variables = [
    "geopotential",
    "relative_humidity",
    "temperature",
    "u_component_of_wind",
    "v_component_of_wind"
]
area = [15.5, 89.5, -15.5, 145.5]  # North, West, South, East

# Create CDS API client
client = cdsapi.Client()

# Loop through the dates
current_date = start_date
while current_date <= end_date:
    # Define the 25-hour time window from 12Z current day to 13Z next day
    times = [f"{h:02d}:00" for h in range(12, 24)]  # From 12:00 to 23:00
    next_day = current_date + timedelta(days=1)
    times += [f"{h:02d}:00" for h in range(0, 14)]  # From 00:00 to 13:00 next day

    # Split times into two sets: one for current day, one for next day
    day1_times = [f"{hour:02d}:00" for hour in range(12, 24)]    # 12:00 to 23:00
    day2_times = [f"{hour:02d}:00" for hour in range(0, 14)]      # 00:00 to 13:00

    # Create output directory
    folder_name = f"{os.environ.get('CAWO_INPUT')}/era5/era5_{current_date.strftime('%Y%m%d')}"
    os.makedirs(folder_name, exist_ok=True)

    # Download for current day (12:00–23:00)
    request_day1 = {
        "product_type": "reanalysis",
        "variable": variables,
        "year": str(current_date.year),
        "month": f"{current_date.month:02d}",
        "day": f"{current_date.day:02d}",
        "time": day1_times,
        "pressure_level": pressure_levels,
        "data_format": "grib",
        "area": area,
    }
    print(f"Downloading {folder_name}/part1.grib")
    import pprint
    pprint.pprint(request_day1)
    client.retrieve(dataset, request_day1).download(f"{folder_name}/era5_pl_part1.grib")

    # Download for next day (00:00–13:00)
    request_day2 = {
        "product_type": "reanalysis",
        "variable": variables,
        "year": str(next_day.year),
        "month": f"{next_day.month:02d}",
        "day": f"{next_day.day:02d}",
        "time": day2_times,
        "pressure_level": pressure_levels,
        "data_format": "grib",
        "area": area,
    }
    print(f"Downloading {folder_name}/part2.grib")
    client.retrieve(dataset, request_day2).download(f"{folder_name}/era5_pl_part2.grib")

    # You can merge the two parts here using `cfgrib` or `wgrib2` if needed

    current_date += timedelta(days=1)

