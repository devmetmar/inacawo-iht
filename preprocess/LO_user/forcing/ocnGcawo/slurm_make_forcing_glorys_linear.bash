#!/bin/bash
#SBATCH --job-name=forcing_array
#SBATCH --ntasks=1                  # One task per job
#SBATCH --cpus-per-task=1           # One CPU per task
#SBATCH --time=00:30:00
#SBATCH --partition=HDCAST
#SBATCH --output=log_make_linear.out


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

echo "Running make linear forcing for date: 2020.01.01"
python make_forcing_glorys_linear.py
