#!/bin/bash
#!/bin/bash
#SBATCH --job-name=forcing_array
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=16
#SBATCH --mem=128G
#SBATCH --time=02:00:00
#SBATCH --partition=HDCAST
#SBATCH --output=LOG/log_start_ocnGcawo.out
#SBATCH --error=LOG/log_start_ocnGcawo.out

source ~/.bashrc
source ~/opt/miniforge3/bin/activate
conda activate loenv
which python

python -u make_forcing_glorys_linear.py
