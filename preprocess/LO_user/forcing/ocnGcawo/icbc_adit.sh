#!/bin/bash
source "${HOME}/inacawo-iht/setup_env.bash"

cd ${LO_USER}/forcing/ocnGcawo/
srun --job-name=icbc_adit python -u make_forcing_glorys_linear.py &> log_icbc_adit_t01.log
wait

sbatch slurm_run_ocnGcawo_parallel_v3.bash