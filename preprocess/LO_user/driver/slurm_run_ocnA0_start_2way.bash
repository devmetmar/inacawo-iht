#!/bin/bash
#SBATCH --job-name=forcing_array
#SBATCH --ntasks=1                  # One task per job
#SBATCH --cpus-per-task=1           # One CPU per task
#SBATCH --time=00:10:00
#SBATCH --partition=HDCAST
#SBATCH --output=log_start_ocnA0.out

source ~/.bashrc
source ~/opt/miniforge3/bin/activate
conda activate loenv

echo "Running forcing for date: 1998.10.01"
/home/cawohdcst_ft2/opt/miniforge3/envs/loenv/bin/python driver_forcing3.py -g cawo -0 "1998.10.01" -s "new" -f ocnA0
