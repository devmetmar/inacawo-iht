#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Created on Thu Mar 14 15:58:36 2024

@author: fsoares

Edited by tyo
- add CAWO_HINDCAST_RUN environment to handle flexible directory mapping
- add logging folder creation inside loop
"""

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

# Define the directory prefix
cawo_hindcast_run_dir = os.environ.get("CAWO_HINDCAST_RUN")
if cawo_hindcast_run_dir is None:
    raise EnvironmentError("CAWO_HINDCAST_RUN must be set in the environment.")

directory_prefix = f"{cawo_hindcast_run_dir}/f"

# Create directories in daily steps
current_date = start_date
while current_date <= end_date:
    # Format the date as "YYYY.MM.DD"
    formatted_date = current_date.strftime("%Y%m%d")
    
    # Create the directory
    directory_name = directory_prefix + formatted_date
    os.makedirs(directory_name, exist_ok=True)
    
    # Move to the next day
    current_date += timedelta(days=1)

    print(f"Folder created at {directory_name}")

print("All folders created successfully.")