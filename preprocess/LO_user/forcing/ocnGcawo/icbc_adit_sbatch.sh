#!/bin/bash
#SBATCH --job-name=mk_forcing
#SBATCH --partition=HDCAST
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --mem=32G
#SBATCH --time=12:00:00
#SBATCH --output=log_mk_forcing_%j.log
#SBATCH --error=log_mk_forcing_%j.log
    
cd /home/cawohdcst_ft2/LO_user/forcing/ocnGcawo/ || exit 1


source /home/cawohdcst_ft2/opt/miniforge3/etc/profile.d/conda.sh
conda activate loenv

python -u make_forcing_glorys_linear.py
