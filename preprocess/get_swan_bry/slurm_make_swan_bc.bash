#!/bin/bash
#SBATCH --job-name=swan_bc
#SBATCH --array=0-0%8
#SBATCH --ntasks=1
#SBATCH --mem=230G
#SBATCH --time=02:00:00
#SBATCH --partition=HDCAST
#SBATCH --output=log/run_swan_bc_%A_%a.log


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

TASK_ID="${SLURM_ARRAY_TASK_ID:-0}"
RUN_DATE=$(date -d "${START_DATE} + ${TASK_ID} day" +%Y%m%d)

if [[ "${RUN_DATE}" -gt "${END_DATE}" ]]; then
  echo "TASK_ID ${TASK_ID} -> ${RUN_DATE} > END_DATE ${END_DATE}. Nothing to do."
  exit 0
fi

echo "TASK_ID ${TASK_ID} processing swan BC ${RUN_DATE}"
# Single-day window (start == end) — days are independent
python make_swan_bc.py "${RUN_DATE}" "${RUN_DATE}"
STATUS=$?
if [[ ${STATUS} -ne 0 ]]; then
  echo "ERROR: make_swan_bc.py failed for ${RUN_DATE} with status ${STATUS}." >&2
  exit "${STATUS}"
fi
echo "Finished swan BC ${RUN_DATE}"
