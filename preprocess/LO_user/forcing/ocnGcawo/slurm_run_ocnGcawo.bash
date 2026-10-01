#!/bin/bash
#!/bin/bash
#SBATCH --job-name=forcing_array
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=8
#SBATCH --mem=64G
#SBATCH --time=02:00:00
#SBATCH --partition=HDCAST
#SBATCH --output=log_ocnGcawo.out
#SBATCH --error=log_ocnGcawo.out

source ~/.bashrc
conda activate loenv

python -u make_forcing_glorys_linear_noini.py
