#!/bin/bash
#SBATCH --job-name=forcing_array
#SBATCH --array=0-3            # Max 96 jobs running at once
#SBATCH --nodes=1                   # Stay on a single node
#SBATCH --ntasks=1                  # One task per job
#SBATCH --cpus-per-task=1           # One CPU per task
#SBATCH --time=10:00:00
#SBATCH --partition=HDCAST
#SBATCH --output=slurm_%A_%a.out

# source ~/.bashrc
# conda activate loenv
source ~/opt/miniforge3/bin/activate
conda activate loenv

start_date="2020-01-02"
date_to_run=$(date -d "$start_date + ${SLURM_ARRAY_TASK_ID} days" +%Y.%m.%d)

echo "Running forcing for date: $date_to_run on $(hostname)"
python driver_forcing3.py -g cawo -0 "$date_to_run" -f ocnA0
