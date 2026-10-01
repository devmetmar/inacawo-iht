#!/bin/bash
#SBATCH --job-name=forcing_array
#SBATCH --ntasks=1                  # One task per job
#SBATCH --cpus-per-task=1           # One CPU per task
#SBATCH --time=00:30:00
#SBATCH --partition=HDCAST
#SBATCH --output=log_make_linear.out

source ~/.bashrc
source ~/opt/miniforge3/bin/activate
conda activate loenv

echo "Running make linear forcing for date: 2020.01.01"
/home/cawohdcst_ft2/opt/miniforge3/envs/loenv/bin/python make_forcing_glorys_linear.py
