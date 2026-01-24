#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Created on Wed Dec  6 10:39:40 2023

@author: fsoares
"""
import os
import copernicusmarine
from datetime import datetime, timedelta

# Define the date range
start_date = datetime(2024, 6, 9)
end_date = datetime(2024, 6, 15)  # Adjust the end date as needed

# Loop through the date range
current_date = start_date
while current_date <= end_date:
    # Convert the current date to string format
    current_date_str = current_date.strftime("%Y-%m-%dT%H:%M:%S")

    # Use copernicusmarine.subset for the current date
    copernicusmarine.subset(
        dataset_id="cmems_mod_glo_phy_myint_0.083deg_P1D-m",
        variables=["so","thetao","uo","vo","zos"],
        minimum_longitude=89.5,
        maximum_longitude=145.5,
        minimum_latitude=-15.5,
        maximum_latitude=15.5,
        start_datetime=current_date_str,
        end_datetime=current_date_str,
        minimum_depth=0.494,
        maximum_depth=5727.9169921875,
        output_filename=f"GLORYS_Reanalysis_LO_{current_date_str}.nc",
        output_directory=f"{os.environ.get('CAWO_INPUT')}/mercator",
        username = "fsoares1",
        password = "Fuconn.2021",
        force_download=True
    )

    # Move to the next date
    current_date += timedelta(days=1)
