#!/bin/bash
#SBATCH --job-name=swan_bc
#SBATCH --ntasks=1
#SBATCH --mem=230G
#SBATCH --time=02:00:00
#SBATCH --partition=HDCAST
#SBATCH --output=run_swan_bc_%j.log


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

# Dates from run_preprocess.bash (IHT_*) or fallback
START_DATE="${IHT_START_DATE:-19950106}"
END_DATE="${IHT_END_DATE:-19950106}"
python make_swan_bc.py "${START_DATE}" "${END_DATE}"
