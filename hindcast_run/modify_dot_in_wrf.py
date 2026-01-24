#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Created on Thu Mar 14 16:06:54 2024

@author: fsoares
"""

import os
import shutil
from datetime import datetime, timedelta

# Set the start date
start_date = datetime(1995, 1, 2)
# Set the end date
end_date = datetime(1995, 1, 5)

# Define the directory prefix
cawo_hindcast_run_dir = os.environ.get("CAWO_HINDCAST_RUN")
cawo_hindcast_output_dir = os.environ.get("CAWO_OUTPUT")
if cawo_hindcast_run_dir is None:
    raise EnvironmentError("CAWO_HINDCAST_RUN must be set in the environment.")

directory_prefix = f"{cawo_hindcast_run_dir}/f"

# Define the source file
source_file = "in_templates/namelist.input.template"

# Iterate through each day and update the files
current_date = start_date
while current_date <= end_date:
    print(f"Processing {current_date} ...")
    # Format the date as "YYYY.MM.DD"
    formatted_date = current_date.strftime("%Y%m%d")
    formatted_year = current_date.strftime("%Y")
    formatted_month = current_date.strftime("%m")
    formatted_day = current_date.strftime("%d")
    # Create the destination directory
    destination_directory = directory_prefix + formatted_date
    os.makedirs(destination_directory, exist_ok=True)
    
    # Construct the destination file path
    destination_file = os.path.join(destination_directory, "namelist.input")
    
    # Copy the template file
    shutil.copy(source_file, destination_file)
    
    # Update the contents of the file
    with open(destination_file, 'r') as file:
        content = file.read()
        
    # Update the BRYNAME and CLMNAME sections
    next_date = current_date + timedelta(days=1)
    next_formatted_date = next_date.strftime("%Y%m%d")
    next_formatted_year = next_date.strftime("%Y")
    next_formatted_month = next_date.strftime("%m")
    next_formatted_day = next_date.strftime("%d")

    previous_date = current_date + timedelta(days=-1)
    previous_formatted_date = previous_date.strftime("%Y%m%d")
    previous_formatted_year = previous_date.strftime("%Y")
    previous_formatted_month = previous_date.strftime("%m")
    previous_formatted_day = previous_date.strftime("%d")

    content = content.replace('today',f'{formatted_date}')
    content = content.replace('tomorrow',f'{next_formatted_date}')
    content = content.replace('yesterday',f'{previous_formatted_date}')
    
    content = content.replace('YYYY1',f'{formatted_year}')
    content = content.replace('MM1',f'{formatted_month}')
    content = content.replace('DD1',f'{formatted_day}')

    content = content.replace('YYYY2',f'{next_formatted_year}')
    content = content.replace('MM2',f'{next_formatted_month}')
    content = content.replace('DD2',f'{next_formatted_day}')

    content = content.replace('CAWO_OUTPUT',f'{cawo_hindcast_output_dir}')

    # ... 
    # Write the updated content back to the file
    with open(destination_file, 'w') as file:
        file.write(content)
    
    # Move to the next day
    current_date += timedelta(days=1)

print("Files updated successfully.")
