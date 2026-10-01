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
# DATE RANGE
# =========================
start_date="1995-01-06"
end_date="1995-01-06"
current_date="$start_date"
MAX_PARALLEL=16   # limit parallel processes
job_count=0
echo "Launching parallel forcing jobs..."
while [[ "$(date -d "$current_date" +%s)" -le "$(date -d "$end_date" +%s)" ]]
do
    formatted_date=$(date -d "$current_date" +%Y.%m.%d)
    echo "Launching forcing for $formatted_date"
    python driver_forcing3.py -g cawo -0 "$formatted_date" -f ocnA0 &
    ((job_count++))
    # limit parallel jobs
    if (( job_count >= MAX_PARALLEL )); then
        wait   # wait for all background jobs
        job_count=0
    fi
    current_date=$(date -d "$current_date + 1 day" +%Y-%m-%d)
done
# wait for remaining jobs
wait
echo "All forcing jobs completed."
