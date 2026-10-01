#!/bin/bash
source "${HOME}/inacawo-iht/setup_env.bash"
#SBATCH --job-name=mk_forcing
#SBATCH --partition=HDCAST
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --mem=32G
#SBATCH --time=12:00:00
#SBATCH --output=log_mk_forcing_%j.log
#SBATCH --error=log_mk_forcing_%j.log
    
cd ${LO_USER}/forcing/ocnGcawo/ || exit 1


source ${CONDA_BASE}/etc/profile.d/conda.sh
conda activate hindcast

python -u make_forcing_glorys_linear.py
