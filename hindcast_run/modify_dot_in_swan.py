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
cawo_hindcast_input_dir = os.environ.get("CAWO_INPUT")
if cawo_hindcast_run_dir is None:
    raise EnvironmentError("CAWO_HINDCAST_RUN must be set in the environment.")

directory_prefix = f"{cawo_hindcast_run_dir}/f"

# Define the source file
source_file = "in_templates/swan.in.template"

# Iterate through each day and update the files
current_date = start_date
while current_date <= end_date:
    print(f"Processing {current_date}")
    # Format the date as "YYYY.MM.DD"
    formatted_date = current_date.strftime("%Y%m%d")
    
    # Create the destination directory
    destination_directory = directory_prefix + formatted_date
    os.makedirs(destination_directory, exist_ok=True)
    
    # Construct the destination file path
    destination_file = os.path.join(destination_directory, "swan.in")
    
    # Copy the template file
    shutil.copy(source_file, destination_file)
    
    # Update the contents of the file
    with open(destination_file, 'r') as file:
        content = file.read()
        
    # Update the BRYNAME and CLMNAME sections
    next_date = current_date + timedelta(days=1)
    next_formatted_date = next_date.strftime("%Y%m%d")
    
    previous_date = current_date + timedelta(days=-1)
    previous_formatted_date = previous_date.strftime("%Y%m%d")
    
    content = content.replace('today',f'{formatted_date}')
    content = content.replace('tomorrow',f'{next_formatted_date}')
    content = content.replace('yesterday',f'{previous_formatted_date}')

    content = content.replace('CAWO_INPUT',f'{cawo_hindcast_input_dir}')
    
    # ... 
    # Write the updated content back to the file
    with open(destination_file, 'w') as file:
        file.write(content)
    
    # Move to the next day
    current_date += timedelta(days=1)

print("Files updated successfully.")
