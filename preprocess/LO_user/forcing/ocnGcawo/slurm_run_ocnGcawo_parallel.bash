#!/bin/bash
#SBATCH --job-name=forcing_array
#SBATCH --array=0-8
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=8
#SBATCH --mem=230G
#SBATCH --time=01:00:00
#SBATCH --partition=HDCAST
#SBATCH --output=log_ocnGcawo_%A_%a.out
#SBATCH --error=log_ocnGcawo_%A_%a.err


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

# List of dates to process
DATES=(
    "1997-12-17"
    "1997-12-25"
    "1998-01-01"
    "1998-01-02"
    "1998-01-03"
    "1998-01-04"
    "1998-01-05"
    "1998-01-06"
)

DATE=${DATES[$SLURM_ARRAY_TASK_ID]}

python -u make_forcing_glorys_linear_parallel.py $DATE
