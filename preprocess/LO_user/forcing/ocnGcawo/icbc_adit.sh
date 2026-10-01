#!/bin/bash

cd /home/cawohdcst_ft2/LO_user/forcing/ocnGcawo/
srun --job-name=icbc_adit /home/cawohdcst_ft2/opt/miniforge3/envs/loenv/bin/python -u make_forcing_glorys_linear.py &> log_icbc_adit_t01.log
wait

sbatch slurm_run_ocnGcawo_parallel_v3.bash