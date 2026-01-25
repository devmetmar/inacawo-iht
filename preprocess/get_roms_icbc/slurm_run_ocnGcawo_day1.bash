#!/bin/bash
#SBATCH --job-name=romsforcd1
#SBATCH --partition=HDCAST
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --mem=32G
#SBATCH --time=12:00:00
#SBATCH --output=log/log_ocnGcawo_1_%j.log
#SBATCH --error=log/log_ocnGcawo_1_%j.log

source ~/.bashrc
source $CONDA_BASE/etc/profile.d/conda.sh
conda activate loenv

RUN_DATE="1995-01-01"

RUN_DATE=$(date -d "${RUN_DATE}" +%Y-%m-%d)

python -u make_forcing_glorys_linear.py $RUN_DATE
