#!/bin/bash
# InaCAWO hindcast_run entrypoint — folders / namelist / copy / submit.
#
# Usage:
#   ./run_hindcast.bash --start YYYYMMDD --end YYYYMMDD [options]
#
# Examples:
#   ./run_hindcast.bash --start 20251231 --end 20260105 --day1
#   ./run_hindcast.bash --start 20260101 --end 20260105
#   ./run_hindcast.bash --start 20251231 --end 20260105 --stage setup
#   ./run_hindcast.bash --start 20251231 --end 20251231 --stage submit --dry-run
#
set -euo pipefail

_HC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_IHT_ROOT="$(cd "${_HC_ROOT}/.." && pwd)"
_ORIG_ARGS=("$@")

_CANONICAL_ORDER=(folders namelist copy submit)

usage() {
  cat <<'EOF'
Usage: run_hindcast.bash --start YYYYMMDD --end YYYYMMDD [options]

Required:
  --start YYYYMMDD          Start date (inclusive)
  --end YYYYMMDD            End date (inclusive)

Stage selection:
  --stage LIST              Comma-separated aliases and/or atomic steps (default: all)

Atomic steps:
  folders   create_folders.py → $CAWO_HINDCAST_RUN/fYYYYMMDD
  namelist  modify_dot_in.py (roms/swan/wrf templates)
  copy      stage coawstM, WPS real, statics, Slurm script into each run dir
  submit    submit_days.bash → sbatch per day

Aliases:
  setup     -> folders,namelist,copy
  all       -> folders,namelist,copy,submit  (default)

Options:
  --day1                    First day of range uses day1 templates + ramp binary;
                            remaining days use continuing templates + no-ramp.
                            If start==end, only that day is day1.
  --dry-run                 Print commands only
  --wait                    Wait for each day's Slurm job (default; DONE + scancel)
  --no-wait                 Submit all days and exit (no DONE poll)
  --partition NAME          Slurm partition override
                            (default: auto — HDCAST if account allowed, else DEV1)
  --no-log                  Do not write $WORK_BASE/logs/ (default: auto-log)
  -v, --verbose             Also mirror log to this terminal (default: quiet)
  -h, --help                Show this help

Logs (default, under iht repo):
  $WORK_BASE/logs/hindcast/hindcast_<start>_<end>_<stage>_<timestamp>.log
  Terminal prints only the log realpath; monitor with: tail -f <logfile>
  Ctrl+C stops local children and scancels submitted SLURM jobs.

Prerequisites:
  preprocess products under $CAWO_INPUT; COAWST binaries under $MODEL_BASE.
EOF
}

# ---------------------------------------------------------------------------
# Arg parse
# ---------------------------------------------------------------------------
START=""
END=""
STAGE="all"
DAY1=0
DRY_RUN=0
WAIT_JOBS=1
PARTITION_ARG=""
NO_LOG=0
VERBOSE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --start) START="${2:-}"; shift 2 ;;
    --end) END="${2:-}"; shift 2 ;;
    --stage) STAGE="${2:-}"; shift 2 ;;
    --day1) DAY1=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --wait) WAIT_JOBS=1; shift ;;
    --no-wait) WAIT_JOBS=0; shift ;;
    --partition) PARTITION_ARG="${2:-}"; shift 2 ;;
    --no-log) NO_LOG=1; shift ;;
    -v|--verbose) VERBOSE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "${START}" || -z "${END}" ]]; then
  echo "ERROR: --start and --end are required" >&2
  usage >&2
  exit 2
fi

if [[ ! "${START}" =~ ^[0-9]{8}$ || ! "${END}" =~ ^[0-9]{8}$ ]]; then
  echo "ERROR: dates must be YYYYMMDD (got start=${START} end=${END})" >&2
  exit 2
fi

if [[ "${START}" -gt "${END}" ]]; then
  echo "ERROR: --start (${START}) > --end (${END})" >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# Env bootstrap
# ---------------------------------------------------------------------------
if [[ "${DRY_RUN}" -eq 0 ]]; then
  export IHT_QUIET=1
  # shellcheck disable=SC1091
  source "${_IHT_ROOT}/setup_env.bash"
else
  export WORK_BASE="${WORK_BASE:-${_IHT_ROOT}}"
fi

# ---------------------------------------------------------------------------
# Auto-log → $WORK_BASE/logs/hindcast/
# ---------------------------------------------------------------------------
IHT_HINDCAST_LOG=""
_CHILD_PID=""
_SBATCH_JOBS=()
_SBATCH_JOBS_FILE=""

_iht_realpath_log() {
  local p="$1"
  if command -v realpath >/dev/null 2>&1; then
    realpath -m "${p}" 2>/dev/null || echo "${p}"
  elif command -v readlink >/dev/null 2>&1; then
    readlink -f "${p}" 2>/dev/null || echo "${p}"
  else
    echo "${p}"
  fi
}

_iht_kill_children() {
  if [[ -n "${_CHILD_PID:-}" ]] && kill -0 "${_CHILD_PID}" 2>/dev/null; then
    kill -TERM -"${_CHILD_PID}" 2>/dev/null || kill -TERM "${_CHILD_PID}" 2>/dev/null || true
    sleep 0.5
    kill -KILL -"${_CHILD_PID}" 2>/dev/null || kill -KILL "${_CHILD_PID}" 2>/dev/null || true
  fi
  local kids
  kids="$(pgrep -P $$ 2>/dev/null || true)"
  if [[ -n "${kids}" ]]; then
    # shellcheck disable=SC2086
    kill -TERM ${kids} 2>/dev/null || true
    sleep 0.3
    # shellcheck disable=SC2086
    kill -KILL ${kids} 2>/dev/null || true
  fi
}

_iht_scancel_jobs() {
  local jid
  if [[ -n "${_SBATCH_JOBS_FILE:-}" && -f "${_SBATCH_JOBS_FILE}" ]]; then
    while read -r jid; do
      [[ -z "${jid}" || "${jid}" == "DRYRUN_JOBID" ]] && continue
      _SBATCH_JOBS+=("${jid}")
    done <"${_SBATCH_JOBS_FILE}"
  fi
  for jid in "${_SBATCH_JOBS[@]:-}"; do
    [[ -z "${jid}" || "${jid}" == "DRYRUN_JOBID" ]] && continue
    scancel "${jid}" 2>/dev/null || true
  done
}

_iht_on_interrupt() {
  local sig="${1:-INT}"
  trap - INT TERM EXIT
  echo "[hindcast] caught SIG${sig}; stopping children / scancel…" || true
  _iht_kill_children
  _iht_scancel_jobs
  echo "[hindcast] interrupted rc=130 at $(date -Is)" || true
  exit 130
}

_iht_on_exit() {
  local rc=$?
  if [[ -n "${_SBATCH_JOBS_FILE:-}" && -f "${_SBATCH_JOBS_FILE}" ]]; then
    rm -f "${_SBATCH_JOBS_FILE}" 2>/dev/null || true
  fi
  if [[ "${rc}" -ne 130 ]]; then
    echo "[hindcast] finished rc=${rc} at $(date -Is)"
    if [[ -n "${IHT_HINDCAST_LOG}" ]]; then
      echo "[hindcast] log → ${IHT_HINDCAST_LOG}"
    fi
  fi
}

if [[ "${NO_LOG}" -eq 0 ]]; then
  export IHT_LOG_DIR="${IHT_LOG_DIR:-${WORK_BASE}/logs}"
  _LOG_DIR="${IHT_LOG_DIR}/hindcast"
  mkdir -p "${_LOG_DIR}"
  _TS="$(date +%Y%m%d_%H%M%S)"
  _TAG="$(echo "${STAGE}" | tr ',/ ' '___' | tr -cd 'A-Za-z0-9._-')"
  [[ -z "${_TAG}" ]] && _TAG="run"
  [[ "${DAY1}" -eq 1 ]] && _TAG="${_TAG}__day1"
  IHT_HINDCAST_LOG="$(_iht_realpath_log "${_LOG_DIR}/hindcast_${START}_${END}_${_TAG}_${_TS}.log")"
  export IHT_HINDCAST_LOG

  exec 3>&1 4>&2
  echo "${IHT_HINDCAST_LOG}" >&3
  if [[ "${VERBOSE}" -eq 1 ]]; then
    exec > >(tee -a "${IHT_HINDCAST_LOG}" >&3) 2>&1
  else
    exec >>"${IHT_HINDCAST_LOG}" 2>&1
  fi
  echo "[hindcast] log started $(date -Is) pid=$$"
  echo "[hindcast] argv: ${_HC_ROOT}/run_hindcast.bash ${_ORIG_ARGS[*]}"
  echo "[hindcast] WORK_BASE=${WORK_BASE} IHT_LOG_DIR=${IHT_LOG_DIR}"
  echo "[hindcast] monitor: tail -f ${IHT_HINDCAST_LOG}"
  trap '_iht_on_interrupt INT' INT
  trap '_iht_on_interrupt TERM' TERM
  trap _iht_on_exit EXIT
else
  trap '_iht_on_interrupt INT' INT
  trap '_iht_on_interrupt TERM' TERM
  trap _iht_on_exit EXIT
fi

# ---------------------------------------------------------------------------
# Date exports
# ---------------------------------------------------------------------------
export IHT_START_DATE="${START}"
export IHT_END_DATE="${END}"
export IHT_START_DATE_ISO="$(date -d "${START}" +%Y-%m-%d)"
export IHT_END_DATE_ISO="$(date -d "${END}" +%Y-%m-%d)"
export IHT_START_DATE_DOT="$(date -d "${START}" +%Y.%m.%d)"
export IHT_END_DATE_DOT="$(date -d "${END}" +%Y.%m.%d)"
export IHT_WAIT_JOBS="${WAIT_JOBS}"

# Slurm partition: HDCAST if account allowed, else DEV1 (avoids PartitionConfig)
# shellcheck source=../src/slurm_partition.bash
source "${_IHT_ROOT}/src/slurm_partition.bash"
_iht_resolve_slurm_partition

# Day1 split: first day vs rest
DAY1_START=""
DAY1_END=""
CONT_START=""
CONT_END=""
if [[ "${DAY1}" -eq 1 ]]; then
  DAY1_START="${START}"
  DAY1_END="${START}"
  if [[ "${START}" -lt "${END}" ]]; then
    CONT_START="$(date -d "${START} + 1 day" +%Y%m%d)"
    CONT_END="${END}"
  fi
else
  CONT_START="${START}"
  CONT_END="${END}"
fi

# ---------------------------------------------------------------------------
# Stage expand
# ---------------------------------------------------------------------------
_expand_token() {
  case "$1" in
    all) echo "folders namelist copy submit" ;;
    setup) echo "folders namelist copy" ;;
    folders|namelist|copy|submit) echo "$1" ;;
    *)
      echo "ERROR: unknown stage token: $1" >&2
      return 1
      ;;
  esac
}

_is_atomic() {
  case "$1" in
    folders|namelist|copy|submit) return 0 ;;
    *) return 1 ;;
  esac
}

declare -A _WANT=()
_IFS_SAVE="${IFS}"
IFS=','
# shellcheck disable=SC2086
for tok in ${STAGE}; do
  IFS="${_IFS_SAVE}"
  tok="$(echo "${tok}" | tr -d '[:space:]')"
  [[ -z "${tok}" ]] && continue
  # shellcheck disable=SC2046
  for a in $(_expand_token "${tok}"); do
    _WANT["${a}"]=1
  done
  IFS=','
done
IFS="${_IFS_SAVE}"

_STEPS=()
for a in "${_CANONICAL_ORDER[@]}"; do
  [[ -n "${_WANT[$a]:-}" ]] && _STEPS+=("${a}")
done

if [[ "${#_STEPS[@]}" -eq 0 ]]; then
  echo "ERROR: no steps selected from --stage=${STAGE}" >&2
  exit 2
fi

echo "[hindcast] ${START} → ${END} (${#_STEPS[@]} step(s))"
echo "[hindcast] steps: ${_STEPS[*]}"
_wait_label=OFF
_dry_label=OFF
_day1_label=OFF
[[ "${WAIT_JOBS}" -eq 1 ]] && _wait_label=ON
[[ "${DRY_RUN}" -eq 1 ]] && _dry_label=ON
[[ "${DAY1}" -eq 1 ]] && _day1_label=ON
echo "[hindcast] wait=${_wait_label} dry-run=${_dry_label} day1=${_day1_label}"
_iht_log_slurm_partition "[hindcast]"
if [[ "${IHT_SLURM_PARTITION}" != "HDCAST" ]]; then
  echo "[hindcast] MPI fabric on ${IHT_SLURM_PARTITION}: restgen-mlx @ 88×96 (UCX_TLS=all, OFI_INTERNAL=0; ATM=6048/WAV=672/OCN=1728)"
fi
if [[ "${DAY1}" -eq 1 ]]; then
  echo "[hindcast] day1 slice: ${DAY1_START} → ${DAY1_END}"
  if [[ -n "${CONT_START}" ]]; then
    echo "[hindcast] continuing slice: ${CONT_START} → ${CONT_END}"
  fi
fi

# ---------------------------------------------------------------------------
# Run helpers
# ---------------------------------------------------------------------------
_run_local() {
  local label="$1"
  shift
  # Pretty-print: hide internal _with_iht_dates helper in dry-run / logs
  local _show=("$@")
  if [[ "${1:-}" == "_with_iht_dates" ]]; then
    _show=("${@:4}")
  fi
  echo "[hindcast] >>> ${label}: ${_show[*]}"
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    echo "[hindcast] (dry-run) skip"
    return 0
  fi
  # shellcheck disable=SC2090
  "$@" &
  _CHILD_PID=$!
  wait "${_CHILD_PID}"
  local rc=$?
  _CHILD_PID=""
  return "${rc}"
}

_with_iht_dates() {
  # Run command with temporary IHT_* date exports (YYYYMMDD start/end).
  local d0="$1" d1="$2"
  shift 2
  (
    export IHT_START_DATE="${d0}"
    export IHT_END_DATE="${d1}"
    export IHT_START_DATE_ISO="$(date -d "${d0}" +%Y-%m-%d)"
    export IHT_END_DATE_ISO="$(date -d "${d1}" +%Y-%m-%d)"
    export IHT_START_DATE_DOT="$(date -d "${d0}" +%Y.%m.%d)"
    export IHT_END_DATE_DOT="$(date -d "${d1}" +%Y.%m.%d)"
    export IHT_QUIET=1
    "$@"
  )
}

_run_step() {
  local step="$1"
  case "${step}" in
    folders)
      _run_local "folders" python "${_HC_ROOT}/create_folders.py" "${START}" "${END}"
      ;;
    namelist)
      if [[ -n "${DAY1_START}" ]]; then
        _run_local "namelist-day1" \
          _with_iht_dates "${DAY1_START}" "${DAY1_END}" \
          python "${_HC_ROOT}/modify_dot_in.py" "${DAY1_START}" "${DAY1_END}" --day1
      fi
      if [[ -n "${CONT_START}" ]]; then
        _run_local "namelist-cont" \
          _with_iht_dates "${CONT_START}" "${CONT_END}" \
          python "${_HC_ROOT}/modify_dot_in.py" "${CONT_START}" "${CONT_END}"
      fi
      ;;
    copy)
      if [[ -n "${DAY1_START}" ]]; then
        _run_local "copy-day1" \
          _with_iht_dates "${DAY1_START}" "${DAY1_END}" \
          bash "${_HC_ROOT}/copy_files_for_run_day1.bash"
      fi
      if [[ -n "${CONT_START}" ]]; then
        _run_local "copy-cont" \
          _with_iht_dates "${CONT_START}" "${CONT_END}" \
          bash "${_HC_ROOT}/copy_files_for_run.bash"
      fi
      ;;
    submit)
      if [[ "${DRY_RUN}" -eq 1 ]]; then
        echo "[hindcast] >>> submit: bash ${_HC_ROOT}/submit_days.bash"
        echo "[hindcast] (dry-run) skip"
        return 0
      fi
      _SBATCH_JOBS_FILE="$(mktemp "${TMPDIR:-/tmp}/iht_hindcast_jobs.XXXXXX")"
      export IHT_SBATCH_JOBS_FILE="${_SBATCH_JOBS_FILE}"
      # Full range for submit (day1 + continuing already staged)
      export IHT_START_DATE="${START}"
      export IHT_END_DATE="${END}"
      export IHT_START_DATE_ISO="$(date -d "${START}" +%Y-%m-%d)"
      export IHT_END_DATE_ISO="$(date -d "${END}" +%Y-%m-%d)"
      echo "[hindcast] >>> submit: bash ${_HC_ROOT}/submit_days.bash (wait=${WAIT_JOBS})"
      bash "${_HC_ROOT}/submit_days.bash" &
      _CHILD_PID=$!
      wait "${_CHILD_PID}"
      local rc=$?
      _CHILD_PID=""
      return "${rc}"
      ;;
    *)
      echo "ERROR: unknown step ${step}" >&2
      return 1
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
for step in "${_STEPS[@]}"; do
  _run_step "${step}"
done

echo "[hindcast] all requested steps completed"
