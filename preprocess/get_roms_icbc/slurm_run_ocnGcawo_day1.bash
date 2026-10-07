#!/bin/bash
#SBATCH --job-name=romsforcd1
#SBATCH --partition=HDCAST
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --mem=32G
#SBATCH --time=12:00:00
#SBATCH --output=log/log_ocnGcawo_1_%j.log
#SBATCH --error=log/log_ocnGcawo_1_%j.log


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

# Date from run_preprocess.bash (IHT_*) or fallback
RUN_DATE="${IHT_START_DATE_ISO:-1995-01-01}"
RUN_DATE=$(date -d "${RUN_DATE}" +%Y-%m-%d)

python -u make_forcing_glorys_linear.py "$RUN_DATE"
