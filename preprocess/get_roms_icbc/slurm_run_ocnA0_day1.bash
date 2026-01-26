#!/bin/bash
#SBATCH --job-name=forcing_parallel
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=4     # number of parallel jobs allowed
#SBATCH --time=01:00:00
#SBATCH --partition=HDCAST
#SBATCH --output=log/log_ocnA0_%j.out

source ~/.bashrc
source $CONDA_BASE/etc/profile.d/conda.sh
conda activate loenv

# =========================
# INIT DAY (new)
# =========================
echo "Running initialization day"
python driver_forcing3.py -g cawo -0 "1995.01.01" -s "new" -f ocnA0