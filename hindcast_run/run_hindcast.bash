#!/bin/bash

start_date="1995-01-01"
end_date="1995-01-05"

current_date=$start_date

while [[ $(date -d "$current_date" +%s) -le $(date -d "$end_date" +%s) ]]; do
    folder_date=$(date -d "$current_date" +%Y%m%d)

    run_dir="$CAWO_HINDCAST_RUN/f$folder_date"
    out_dir="$CAWO_OUTPUT/f$folder_date"

    echo "===================================="
    echo "Running date: $folder_date"
    echo "Run dir: $run_dir"
    echo "===================================="

    cd "$run_dir" || exit 1

    mkdir -p "$out_dir"

    sync
    sleep 2

    jobid=$(sbatch slurm_run_cawo_3way_hdcst.bash | awk '{print $4}')
    echo "Job submitted: $jobid"

    # Wait until job finishes
    while squeue -j "$jobid" -h > /dev/null; do
        sleep 30
    done

    echo "Job $jobid finished."

    current_date=$(date -d "$current_date + 1 day" +%Y-%m-%d)
done

rm -f PRINT*