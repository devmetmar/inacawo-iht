#!/bin/bash

source ~/.bashrc
source $CONDA_BASE/etc/profile.d/conda.sh
source $COAWST_ENV

start_date="1995-1-1"
end_date="1995-1-5"

CAWO_HINDCAST_OUTPUT=$CAWO_OUTPUT
CAWO_HINDCAST_RUN=$CAWO_HINDCAST_RUN

current_date=$start_date
while [[ $(date -d "$current_date" +%s) -le $(date -d "$end_date" +%s) ]]; do
    folder_date=$(date -d "$current_date" +%Y%m%d)
    
    # Enter the run folder
    cd "$CAWO_HINDCAST_RUN/f$folder_date/"
    echo "Entering $CAWO_HINDCAST_RUN/f$folder_date/"
    # Create output directory
    mkdir -p $CAWO_HINDCAST_OUTPUT/f"$folder_date"/

    # Submit slurm job and capture job ID
    jobid=$(sbatch slurm_run_cawo_3way_hdcst.bash | awk '{print $4}')

    echo "Job submitted for $folder_date. Jobid: $jobid"
    log_file=log_run_${jobid}.out

    # Wait until DONE appears in the log
    status=0
    while [[ $status -eq 0 ]]; do
        sleep 10
        if [[ -f $log_file ]]; then
            status=$(tail -1000 "$log_file" | grep -c "ROMS/TOMS: DONE")
        fi
    done

    echo "DONE detected for $folder_date, cancelling job $jobid ..."
    scancel "$jobid"

    # Move to next date
    current_date=$(date -d "$current_date + 1 day" +%Y-%m-%d)
done

rm PRINT*