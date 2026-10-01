#!/bin/bash
#SBATCH --job-name=forcing_batches
#SBATCH --array=0-365%8            # <-- set this after reading the note below
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=8
#SBATCH --mem=230G
#SBATCH --time=04:00:00
#SBATCH --partition=HDCAST
#SBATCH --output=log_ocnGcawo_%A_%a.out
#SBATCH --error=log_ocnGcawo_%A_%a.err

source ~/.bashrc
conda activate loenv

########################################
# USER INPUT: just change these two
########################################
START_DATE="1997-03-29"
END_DATE="1997-12-31"    # inclusive

# How many days per batch (each array task processes this many days serially)
BATCH_SIZE=8
########################################

# --------------------------------------
# Build the DATE_LIST array dynamically
# --------------------------------------
DATE_LIST=()
current="$START_DATE"

while true; do
    DATE_LIST+=("$current")

    # stop if we've reached END_DATE
    if [ "$current" == "$END_DATE" ]; then
        break
    fi

    # increment by 1 day
    current=$(date -d "$current +1 day" +%Y-%m-%d)
done

TOTAL_DATES=${#DATE_LIST[@]}

echo "Total dates to process: $TOTAL_DATES"
echo "First date: ${DATE_LIST[0]}"
echo "Last date:  ${DATE_LIST[$((TOTAL_DATES-1))]}"

# --------------------------------------
# Figure out which slice this array task handles
# --------------------------------------
TASK_ID=${SLURM_ARRAY_TASK_ID}

START_IDX=$(( TASK_ID * BATCH_SIZE ))
END_IDX=$(( START_IDX + BATCH_SIZE - 1 ))

echo "SLURM_ARRAY_TASK_ID = $TASK_ID"
echo "This batch will handle indices $START_IDX .. $END_IDX"

if [ $START_IDX -ge $TOTAL_DATES ]; then
    echo "Nothing to do for TASK_ID=$TASK_ID (start index beyond list). Exiting."
    exit 0
fi

# --------------------------------------
# Loop through this batch's dates
# --------------------------------------
for (( i=$START_IDX; i<=$END_IDX; i++ )); do

    if [ $i -ge $TOTAL_DATES ]; then
        echo "Index $i >= TOTAL_DATES ($TOTAL_DATES). Done with this batch."
        break
    fi

    RUN_DATE=${DATE_LIST[$i]}
    echo "[$(date)] Starting date $RUN_DATE (index $i)"

    python -u make_forcing_glorys_linear_parallel.py "$RUN_DATE"
    STATUS=$?

    if [ $STATUS -ne 0 ]; then
        echo "ERROR: python failed for $RUN_DATE with status $STATUS. Stopping this batch."
        exit $STATUS
    fi

    echo "[$(date)] Finished $RUN_DATE"
    echo "-------------------------------------------"
done

echo "Batch $TASK_ID complete."
