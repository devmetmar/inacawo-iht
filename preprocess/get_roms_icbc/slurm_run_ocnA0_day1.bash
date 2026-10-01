#!/bin/bash
#SBATCH --job-name=forcing_parallel
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=4     # number of parallel jobs allowed
#SBATCH --time=01:00:00
#SBATCH --partition=HDCAST
#SBATCH --output=log/log_ocnA0_%j.out


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

# =========================
# INIT DAY (new)
# =========================
echo "Running initialization day"
python driver_forcing3.py -g cawo -0 "1995.01.01" -s "new" -f ocnA0