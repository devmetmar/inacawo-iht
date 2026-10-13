#!/bin/bash
# Submit per-day COAWST 3-way Slurm jobs under $CAWO_HINDCAST_RUN/fYYYYMMDD.
# Dates: prefer IHT_START_DATE_ISO / IHT_END_DATE_ISO (or YYYYMMDD IHT_*).
# Optional: IHT_SLURM_PARTITION, IHT_WAIT_JOBS (1=wait DONE+scancel, 0=submit only),
#           IHT_SBATCH_JOBS_FILE (append job IDs for parent scancel).
#
set -euo pipefail

# InaCAWO portable env + hindcast conda (skip if already loaded by entrypoint)
if [[ -z "${CAWO_HINDCAST_RUN:-}" ]]; then
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
fi

# Dates: IHT_* preferred; fallback for manual runs
if [[ -n "${IHT_START_DATE_ISO:-}" && -n "${IHT_END_DATE_ISO:-}" ]]; then
  start_date="${IHT_START_DATE_ISO}"
  end_date="${IHT_END_DATE_ISO}"
elif [[ -n "${IHT_START_DATE:-}" && -n "${IHT_END_DATE:-}" ]]; then
  start_date="$(date -d "${IHT_START_DATE}" +%Y-%m-%d)"
  end_date="$(date -d "${IHT_END_DATE}" +%Y-%m-%d)"
else
  start_date="1995-01-02"
  end_date="1995-01-05"
fi

WAIT_JOBS="${IHT_WAIT_JOBS:-1}"

# Always pick a partition (entrypoint usually already set IHT_SLURM_PARTITION).
# Manual runs of this script alone still get HDCAST→DEV1 auto-fallback.
if [[ -z "${IHT_SLURM_PARTITION:-}" ]]; then
  _iht_root="${WORK_BASE:-${HOME}/inacawo-iht}"
  if [[ -f "${_iht_root}/src/slurm_partition.bash" ]]; then
    # shellcheck source=../src/slurm_partition.bash
    source "${_iht_root}/src/slurm_partition.bash"
    PARTITION_ARG=""
    _iht_resolve_slurm_partition
    _iht_log_slurm_partition "[submit_days]"
  else
    echo "ERROR: IHT_SLURM_PARTITION unset and ${_iht_root}/src/slurm_partition.bash missing" >&2
    exit 1
  fi
fi
_SBATCH_EXTRA=(--partition="${IHT_SLURM_PARTITION}")
echo "[submit_days] partition=${IHT_SLURM_PARTITION}"

_record_job() {
  local jid="$1"
  if [[ -n "${IHT_SBATCH_JOBS_FILE:-}" ]]; then
    echo "${jid}" >>"${IHT_SBATCH_JOBS_FILE}"
  fi
}

current_date=$start_date

while [[ $(date -d "$current_date" +%s) -le $(date -d "$end_date" +%s) ]]; do
  folder_date=$(date -d "$current_date" +%Y%m%d)

  run_dir="$CAWO_HINDCAST_RUN/f$folder_date"
  out_dir="$CAWO_OUTPUT/f$folder_date"

  echo "===================================="
  echo "Running date: $folder_date"
  echo "Run dir: $run_dir"
  echo "===================================="

  cd "$run_dir" || exit 1

  mkdir -p "$out_dir"

  sync
  sleep 2

  if [[ ! -f slurm_run_cawo_3way_hdcst.bash ]]; then
    echo "ERROR: missing slurm_run_cawo_3way_hdcst.bash in ${run_dir} (run copy stage first)" >&2
    exit 1
  fi

  jobid=$(sbatch "${_SBATCH_EXTRA[@]}" slurm_run_cawo_3way_hdcst.bash | awk '{print $4}')
  echo "Job submitted: $jobid"
  _record_job "$jobid"

  if [[ "${WAIT_JOBS}" -eq 0 ]]; then
    current_date=$(date -d "$current_date + 1 day" +%Y-%m-%d)
    continue
  fi

  log_file=log_run_${jobid}.out
  # Wait until DONE appears in the log
  status=0
  while [[ $status -eq 0 ]]; do
    sleep 10
    if [[ -f $log_file ]]; then
      status=$(tail -1000 "$log_file" | grep -c "ROMS/TOMS: DONE" || true)
    fi
    # Bail if job vanished without DONE (failed / cancelled)
    if ! squeue -j "$jobid" -h 2>/dev/null | grep -q .; then
      # Job left queue — check sacct once more for DONE in log
      if [[ -f $log_file ]]; then
        status=$(tail -1000 "$log_file" | grep -c "ROMS/TOMS: DONE" || true)
      fi
      if [[ $status -eq 0 ]]; then
        echo "ERROR: job $jobid left queue without ROMS/TOMS: DONE" >&2
        if [[ -f $log_file ]]; then
          tail -40 "$log_file" >&2 || true
        fi
        exit 1
      fi
      break
    fi
  done

  # Wait until job finishes
  while squeue -j "$jobid" -h 2>/dev/null | grep -q .; do
    sleep 30
  done

  echo "DONE detected for $folder_date, cancelling job $jobid ..."
  scancel "$jobid" 2>/dev/null || true
  echo "Job $jobid finished."

  current_date=$(date -d "$current_date + 1 day" +%Y-%m-%d)
done

rm -f PRINT*
