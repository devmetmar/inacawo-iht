#!/bin/bash
#SBATCH --job-name=swan_bc
#SBATCH --ntasks=1
#SBATCH --mem=230G
#SBATCH --time=02:00:00
#SBATCH --partition=HDCAST
#SBATCH --output=run_swan_bc_%j.log

source ~/.bashrc
source $CONDA_BASE/etc/profile.d/conda.sh
conda activate loenv

# Run the Python scrip
python make_swan_bc.py 19950106 19950106
