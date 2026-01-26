#!/bin/bash
#SBATCH --job-name=forcing_days
#SBATCH --array=0-365%8      # up to 366 days, max 8 running in parallel
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=8
#SBATCH --mem=230G
#SBATCH --time=04:00:00      # time per *day* now, not per 8-day batch
#SBATCH --partition=HDCAST
#SBATCH --output=log/log_ocnGcawo_%A_%a.out
#SBATCH --error=log/log_ocnGcawo_%A_%a.err

source ~/.bashrc
source $CONDA_BASE/etc/profile.d/conda.sh
conda activate loenv

########################################
# USER INPUT
########################################
START_DATE="1995-01-02"
END_DATE="1995-01-05"    # inclusive
########################################

TASK_ID=${SLURM_ARRAY_TASK_ID}

# Compute this task's date: START_DATE + TASK_ID days
RUN_DATE=$(date -d "${START_DATE} + ${TASK_ID} day" +%Y-%m-%d)

# If we’ve gone past END_DATE, this task has nothing to do
if [[ "$RUN_DATE" > "$END_DATE" ]]; then
    echo "TASK_ID $TASK_ID -> RUN_DATE $RUN_DATE > END_DATE $END_DATE. Nothing to do."
    exit 0
fi

echo "TASK_ID $TASK_ID processing date $RUN_DATE"

python -u make_forcing_glorys_linear_parallel.py "$RUN_DATE"
STATUS=$?

if [ $STATUS -ne 0 ]; then
    echo "ERROR: python failed for $RUN_DATE with status $STATUS."
    exit $STATUS
fi

echo "Finished $RUN_DATE"

