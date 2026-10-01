#!/bin/bash
#SBATCH --partition=HDCAST
#SBATCH --job-name=test_frc_template        #passed by script
#SBATCH --nodes=1                #passed by script
#SBATCH --ntasks-per-node=1
#SBATCH --exclusive
#SBATCH --time=100:00
#SBATCH --output=log.txt #passed by script

bash

/home/cawohdcst/miniconda3/bin/conda activate loenv

python driver_forcing3.py -g cawo -0 "2024.06.10" -s 'new' -f ocnA0
