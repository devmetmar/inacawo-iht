#!/bin/bash
#SBATCH --job-name=forcing_array
#SBATCH --ntasks=1                  # One task per job
#SBATCH --cpus-per-task=1           # One CPU per task
#SBATCH --time=00:10:00
#SBATCH --partition=HDCAST
#SBATCH --output=log_start_ocnA0.out


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

echo "Running forcing for date: 2020.01.01"
python driver_forcing3.py -g cawo -0 "2020.01.01" -s "new" -f ocnA0
