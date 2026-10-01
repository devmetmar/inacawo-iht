#!/bin/bash

# Set the initial date
current_date="1995-01-03"

# Loop for 365 days
for ((i=1; i<=365; i++))
do
    # Convert the date to the "YYYY.MM.DD" format
    formatted_date=$(date -d "$current_date" +%Y.%m.%d)
    
    # Run the command with the current date
    python driver_forcing3.py -g cawo -0 "$formatted_date" -f ocnA0
    
    # Increment the date by one day using the 'date' command
    current_date=$(date -d "$current_date + 1 day" +%Y-%m-%d)
done
