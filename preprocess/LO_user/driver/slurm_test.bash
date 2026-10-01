#!/bin/bash
#SBATCH --partition=HDCAST
#SBATCH --job-name=test_frc_template        #passed by script
#SBATCH --nodes=1                #passed by script
#SBATCH --ntasks-per-node=1
#SBATCH --exclusive
#SBATCH --time=100:00
#SBATCH --output=log.txt #passed by script


# InaCAWO portable env + hindcast conda
if [[ -f "${HOME}/inacawo-iht/setup_env.bash" ]]; then
  # shellcheck disable=SC1091
  source "${HOME}/inacawo-iht/setup_env.bash"
elif [[ -n "${WORK_BASE:-}" && -f "${WORK_BASE}/setup_env.bash" ]]; then
  # shellcheck disable=SC1091
  source "${WORK_BASE}/setup_env.bash"
else
  echo "ERROR: missing setup_env.bash" >&2
  exit 1
fi

python driver_forcing3.py -g cawo -0 "2024.06.10" -s 'new' -f ocnA0
