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
# DATE RANGE (IHT_* from run_preprocess.bash)
# =========================
start_date="${IHT_START_DATE_ISO:-1995-01-06}"
end_date="${IHT_END_DATE_ISO:-1995-01-06}"
current_date="$start_date"
MAX_PARALLEL=16   # limit parallel processes
job_count=0
fail=0
pids=()

echo "Launching parallel forcing jobs..."
while [[ "$(date -d "$current_date" +%s)" -le "$(date -d "$end_date" +%s)" ]]
do
    formatted_date=$(date -d "$current_date" +%Y.%m.%d)
    echo "Launching forcing for $formatted_date"
    python driver_forcing3.py -g cawo -0 "$formatted_date" -f ocnA0 &
    pids+=($!)
    ((job_count++))
    if (( job_count >= MAX_PARALLEL )); then
        for pid in "${pids[@]}"; do
            wait "${pid}" || fail=1
        done
        pids=()
        job_count=0
    fi
    current_date=$(date -d "$current_date + 1 day" +%Y-%m-%d)
done
for pid in "${pids[@]:-}"; do
    wait "${pid}" || fail=1
done

if [[ "${fail}" -ne 0 ]]; then
    echo "ERROR: one or more ocnA0 forcing jobs failed" >&2
    exit 1
fi
echo "All forcing jobs completed."
