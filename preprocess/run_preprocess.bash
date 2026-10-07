#!/bin/bash
# InaCAWO preprocess entrypoint — orchestrate download / WPS / SWAN / ROMS forcing.
#
# Usage:
#   ./run_preprocess.bash --start YYYYMMDD --end YYYYMMDD [options]
#
# Examples:
#   ./run_preprocess.bash --start 19950101 --end 19950105
#   ./run_preprocess.bash --start 19950101 --end 19950105 --stage download
#   ./run_preprocess.bash --start 19950101 --end 19950105 --stage download --model era5-pl
#   ./run_preprocess.bash --start 19950101 --end 19950101 --stage roms --day1
#   ./run_preprocess.bash --start 19950101 --end 19950105 --stage wps --dry-run
#
set -euo pipefail

_PRE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_IHT_ROOT="$(cd "${_PRE_ROOT}/.." && pwd)"
_ORIG_ARGS=("$@")

# ---------------------------------------------------------------------------
# Canonical step order (dependency-safe)
# ---------------------------------------------------------------------------
_CANONICAL_ORDER=(
  era5-sfc era5-pl era5-waves glorys
  ungrib metgrid real
  swan
  roms-a0 roms-gcawo
)

usage() {
  cat <<'EOF'
Usage: run_preprocess.bash --start YYYYMMDD --end YYYYMMDD [options]

Required:
  --start YYYYMMDD          Start date (inclusive)
  --end YYYYMMDD            End date (inclusive)

Stage selection:
  --stage LIST              Comma-separated aliases and/or atomic steps (default: all)
  --model LIST              Optional filter: keep only these atomic steps within --stage

Atomic steps:
  era5-sfc  era5-pl  era5-waves  glorys
  ungrib  metgrid  real
  swan
  roms-a0  roms-gcawo

Aliases:
  era5      -> era5-sfc,era5-pl,era5-waves
  download  -> era5 + glorys
  wps       -> ungrib,metgrid,real
  roms      -> roms-a0,roms-gcawo
  all       -> download,wps,swan,roms  (default)

Options:
  --day1                    Use ROMS day-1 scripts (ocnA0/ocnGcawo day1)
  --glorys-product NAME     reanalysis (default) | interim
  --dry-run                 Print commands only
  --wait                    After sbatch, wait until jobs finish
  --no-log                  Do not write $WORK_BASE/logs/ (default: auto-log)
  -v, --verbose             Also mirror log to this terminal (default: quiet)
  -h, --help                Show this help

Logs (default, under iht repo):
  $WORK_BASE/logs/preprocess/preprocess_<start>_<end>_<stage>_<timestamp>.log
  Terminal prints only the log realpath; monitor with: tail -f <logfile>
  Ctrl+C stops local children and scancels submitted SLURM jobs.

Semantics:
  --stage download                  all downloads
  --stage download --model era5-pl  only pressure-level ERA5
  --stage era5-pl                   same as above
EOF
}

# ---------------------------------------------------------------------------
# Arg parse
# ---------------------------------------------------------------------------
START=""
END=""
STAGE="all"
MODEL=""
DAY1=0
GLORYS_PRODUCT="reanalysis"
DRY_RUN=0
WAIT_JOBS=0
NO_LOG=0
VERBOSE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --start) START="${2:-}"; shift 2 ;;
    --end) END="${2:-}"; shift 2 ;;
    --stage) STAGE="${2:-}"; shift 2 ;;
    --model) MODEL="${2:-}"; shift 2 ;;
    --day1) DAY1=1; shift ;;
    --glorys-product) GLORYS_PRODUCT="${2:-}"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --wait) WAIT_JOBS=1; shift ;;
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

case "${GLORYS_PRODUCT}" in
  reanalysis|interim) ;;
  *)
    echo "ERROR: --glorys-product must be reanalysis or interim" >&2
    exit 2
    ;;
esac

# ---------------------------------------------------------------------------
# Env bootstrap (skip heavy path dump noise)
# ---------------------------------------------------------------------------
if [[ "${DRY_RUN}" -eq 0 ]]; then
  export IHT_QUIET=1
  # shellcheck disable=SC1091
  source "${_IHT_ROOT}/setup_env.bash"
else
  export WORK_BASE="${WORK_BASE:-${_IHT_ROOT}}"
fi

# ---------------------------------------------------------------------------
# Auto-log → $WORK_BASE/logs/preprocess/ (portable under iht repo)
# Default: quiet terminal (realpath only); full output goes to the log.
# ---------------------------------------------------------------------------
IHT_PREPROCESS_LOG=""
_CHILD_PID=""
_SBATCH_JOBS=()

_iht_realpath_log() {
  local p="$1"
  if command -v realpath >/dev/null 2>&1; then
    # -m: canonicalize even if the file was just created / about to be written
    realpath -m "${p}" 2>/dev/null || echo "${p}"
  elif command -v readlink >/dev/null 2>&1; then
    readlink -f "${p}" 2>/dev/null || echo "${p}"
  else
    echo "${p}"
  fi
}

_iht_kill_children() {
  # Stop local foreground/background child (python downloads, etc.)
  if [[ -n "${_CHILD_PID:-}" ]] && kill -0 "${_CHILD_PID}" 2>/dev/null; then
    kill -TERM -"${_CHILD_PID}" 2>/dev/null || kill -TERM "${_CHILD_PID}" 2>/dev/null || true
    sleep 0.5
    kill -KILL -"${_CHILD_PID}" 2>/dev/null || kill -KILL "${_CHILD_PID}" 2>/dev/null || true
  fi
  # Also reap any direct children of this shell
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
  for jid in "${_SBATCH_JOBS[@]:-}"; do
    [[ -z "${jid}" || "${jid}" == "DRYRUN_JOBID" ]] && continue
    scancel "${jid}" 2>/dev/null || true
  done
}

_iht_on_interrupt() {
  local sig="${1:-INT}"
  trap - INT TERM EXIT
  echo "[preprocess] caught SIG${sig}; stopping children / scancel…" || true
  _iht_kill_children
  _iht_scancel_jobs
  echo "[preprocess] interrupted rc=130 at $(date -Is)" || true
  exit 130
}

_iht_on_exit() {
  local rc=$?
  # Avoid double-kill noise on clean exit
  if [[ "${rc}" -ne 130 ]]; then
    echo "[preprocess] finished rc=${rc} at $(date -Is)"
    if [[ -n "${IHT_PREPROCESS_LOG}" ]]; then
      echo "[preprocess] log → ${IHT_PREPROCESS_LOG}"
    fi
  fi
}

if [[ "${NO_LOG}" -eq 0 ]]; then
  export IHT_LOG_DIR="${IHT_LOG_DIR:-${WORK_BASE}/logs}"
  _LOG_DIR="${IHT_LOG_DIR}/preprocess"
  mkdir -p "${_LOG_DIR}"
  _TS="$(date +%Y%m%d_%H%M%S)"
  _TAG="$(echo "${STAGE}" | tr ',/ ' '___' | tr -cd 'A-Za-z0-9._-')"
  if [[ -n "${MODEL}" ]]; then
    _TAG="${_TAG}__$(echo "${MODEL}" | tr ',/ ' '___' | tr -cd 'A-Za-z0-9._-')"
  fi
  [[ -z "${_TAG}" ]] && _TAG="run"
  IHT_PREPROCESS_LOG="$(_iht_realpath_log "${_LOG_DIR}/preprocess_${START}_${END}_${_TAG}_${_TS}.log")"
  export IHT_PREPROCESS_LOG

  # Keep a handle to the real terminal, then redirect body to the log.
  exec 3>&1 4>&2
  # Quiet default: only print realpath for `tail -f`
  echo "${IHT_PREPROCESS_LOG}" >&3
  if [[ "${VERBOSE}" -eq 1 ]]; then
    exec > >(tee -a "${IHT_PREPROCESS_LOG}" >&3) 2>&1
  else
    exec >>"${IHT_PREPROCESS_LOG}" 2>&1
  fi
  echo "[preprocess] log started $(date -Is) pid=$$"
  echo "[preprocess] argv: ${_PRE_ROOT}/run_preprocess.bash ${_ORIG_ARGS[*]}"
  echo "[preprocess] WORK_BASE=${WORK_BASE} IHT_LOG_DIR=${IHT_LOG_DIR}"
  echo "[preprocess] monitor: tail -f ${IHT_PREPROCESS_LOG}"
  trap '_iht_on_interrupt INT' INT
  trap '_iht_on_interrupt TERM' TERM
  trap _iht_on_exit EXIT
else
  trap '_iht_on_interrupt INT' INT
  trap '_iht_on_interrupt TERM' TERM
fi

export IHT_START_DATE="${START}"
export IHT_END_DATE="${END}"
export IHT_START_DATE_ISO="$(date -d "${START}" +%Y-%m-%d)"
export IHT_END_DATE_ISO="$(date -d "${END}" +%Y-%m-%d)"
export IHT_START_DATE_DOT="$(date -d "${START}" +%Y.%m.%d)"
export IHT_END_DATE_DOT="$(date -d "${END}" +%Y.%m.%d)"

_DAYS=$(( ( $(date -d "${END}" +%s) - $(date -d "${START}" +%s) ) / 86400 + 1 ))
_ARRAY_MAX=$((_DAYS - 1))

# ---------------------------------------------------------------------------
# Stage expand + model filter
# ---------------------------------------------------------------------------
_expand_token() {
  local t="$1"
  case "$t" in
    all) echo "era5-sfc era5-pl era5-waves glorys ungrib metgrid real swan roms-a0 roms-gcawo" ;;
    download) echo "era5-sfc era5-pl era5-waves glorys" ;;
    era5) echo "era5-sfc era5-pl era5-waves" ;;
    wps) echo "ungrib metgrid real" ;;
    roms) echo "roms-a0 roms-gcawo" ;;
    era5-sfc|era5-pl|era5-waves|glorys|ungrib|metgrid|real|swan|roms-a0|roms-gcawo)
      echo "$t"
      ;;
    *)
      echo "ERROR: unknown stage token: $t" >&2
      return 1
      ;;
  esac
}

_is_atomic() {
  case "$1" in
    era5-sfc|era5-pl|era5-waves|glorys|ungrib|metgrid|real|swan|roms-a0|roms-gcawo) return 0 ;;
    *) return 1 ;;
  esac
}

# Build selected set from --stage
declare -A _SELECTED=()
IFS=',' read -r -a _STAGE_TOKENS <<< "${STAGE}"
for tok in "${_STAGE_TOKENS[@]}"; do
  tok="$(echo "${tok}" | tr -d '[:space:]')"
  [[ -z "${tok}" ]] && continue
  # shellcheck disable=SC2046
  for step in $(_expand_token "${tok}"); do
    _SELECTED["${step}"]=1
  done
done

# Optional --model filter (must be atomic and subset of selected)
if [[ -n "${MODEL}" ]]; then
  declare -A _FILTER=()
  IFS=',' read -r -a _MODEL_TOKENS <<< "${MODEL}"
  for tok in "${_MODEL_TOKENS[@]}"; do
    tok="$(echo "${tok}" | tr -d '[:space:]')"
    [[ -z "${tok}" ]] && continue
    if ! _is_atomic "${tok}"; then
      # allow nested aliases inside --model too (era5, wps, roms, download)
      # shellcheck disable=SC2046
      for step in $(_expand_token "${tok}"); do
        _FILTER["${step}"]=1
      done
    else
      _FILTER["${tok}"]=1
    fi
  done
  for step in "${!_FILTER[@]}"; do
    if [[ -z "${_SELECTED[${step}]+x}" ]]; then
      echo "ERROR: --model '${step}' is not in expanded --stage (${STAGE})" >&2
      echo "       expanded stage steps: ${!_SELECTED[*]}" >&2
      exit 2
    fi
  done
  unset _SELECTED
  declare -A _SELECTED=()
  for step in "${!_FILTER[@]}"; do
    _SELECTED["${step}"]=1
  done
fi

# Ordered list of steps to run
_STEPS=()
for step in "${_CANONICAL_ORDER[@]}"; do
  if [[ -n "${_SELECTED[${step}]+x}" ]]; then
    _STEPS+=("${step}")
  fi
done

if [[ "${#_STEPS[@]}" -eq 0 ]]; then
  echo "ERROR: no steps selected" >&2
  exit 2
fi

echo "[preprocess] ${IHT_START_DATE} → ${IHT_END_DATE} (${_DAYS} day(s))"
echo "[preprocess] steps: ${_STEPS[*]}"
[[ "${DAY1}" -eq 1 ]] && echo "[preprocess] ROMS mode: day1"
[[ "${DRY_RUN}" -eq 1 ]] && echo "[preprocess] DRY-RUN"

# ---------------------------------------------------------------------------
# Run helpers
# ---------------------------------------------------------------------------
_run_local() {
  local desc="$1"; shift
  local rc=0
  echo "[run] ${desc}" >&2
  echo "      $*" >&2
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    return 0
  fi
  # New process group so Ctrl+C can kill the whole subtree (python, etc.)
  set -m
  "$@" &
  _CHILD_PID=$!
  set +m
  wait "${_CHILD_PID}" || rc=$?
  _CHILD_PID=""
  return "${rc}"
}

# Submit sbatch; prints job id on stdout only. Extra sbatch args after script path.

_sbatch() {
  local script="$1"; shift
  local extra=("$@")
  local export_list="ALL,IHT_START_DATE=${IHT_START_DATE},IHT_END_DATE=${IHT_END_DATE}"
  export_list+=",IHT_START_DATE_ISO=${IHT_START_DATE_ISO},IHT_END_DATE_ISO=${IHT_END_DATE_ISO}"
  export_list+=",IHT_START_DATE_DOT=${IHT_START_DATE_DOT},IHT_END_DATE_DOT=${IHT_END_DATE_DOT}"

  local cmd=(sbatch --export="${export_list}" "${extra[@]}" "${script}")
  echo "[sbatch] ${cmd[*]}" >&2
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    echo "DRYRUN_JOBID"
    return 0
  fi
  local out jid
  out="$("${cmd[@]}")"
  echo "${out}" >&2
  jid="$(echo "${out}" | awk '{print $NF}')"
  _SBATCH_JOBS+=("${jid}")
  echo "${jid}"
}

_wait_jobs() {
  if [[ "${WAIT_JOBS}" -ne 1 || "${DRY_RUN}" -eq 1 ]]; then
    return 0
  fi
  if [[ "${#_SBATCH_JOBS[@]}" -eq 0 ]]; then
    return 0
  fi
  echo "[preprocess] waiting for jobs: ${_SBATCH_JOBS[*]}"
  local jid state
  for jid in "${_SBATCH_JOBS[@]}"; do
    while true; do
      state="$(squeue -h -j "${jid}" -o '%T' 2>/dev/null || true)"
      if [[ -z "${state}" ]]; then
        # finished / unknown — check sacct if available
        break
      fi
      case "${state}" in
        COMPLETED|COMPLETING) break ;;
        FAILED|CANCELLED|TIMEOUT|NODE_FAIL|OUT_OF_MEMORY|PREEMPTED)
          echo "ERROR: job ${jid} ended with state ${state}" >&2
          exit 1
          ;;
      esac
      sleep 30
    done
    if command -v sacct >/dev/null 2>&1; then
      state="$(sacct -n -X -j "${jid}" -o State --parsable2 2>/dev/null | head -n1 | tr -d ' ')"
      case "${state}" in
        COMPLETED|"") ;;
        *)
          echo "ERROR: job ${jid} sacct state=${state}" >&2
          exit 1
          ;;
      esac
    fi
    echo "[preprocess] job ${jid} done"
  done
}

# Track last WPS job for afterok chain within this invocation
_LAST_WPS_DEP=""

_run_step() {
  local step="$1"
  local jid=""
  case "${step}" in
    era5-sfc)
      _run_local "era5-sfc" \
        python "${_PRE_ROOT}/get_era5/get_era5_surface_automate.py" \
        "${IHT_START_DATE}" "${IHT_END_DATE}"
      ;;
    era5-pl)
      _run_local "era5-pl" \
        python "${_PRE_ROOT}/get_era5/get_era5_pl_automate.py" \
        "${IHT_START_DATE}" "${IHT_END_DATE}"
      ;;
    era5-waves)
      _run_local "era5-waves" \
        python "${_PRE_ROOT}/get_era5/get_era5_waves.py" \
        "${IHT_START_DATE}" "${IHT_END_DATE}"
      ;;
    glorys)
      local gpy="${_PRE_ROOT}/get_glorys/get_glorys_reanalysis.py"
      if [[ "${GLORYS_PRODUCT}" == "interim" ]]; then
        gpy="${_PRE_ROOT}/get_glorys/get_glorys_reanalysis_interim.py"
      fi
      _run_local "glorys (${GLORYS_PRODUCT})" \
        python "${gpy}" "${IHT_START_DATE}" "${IHT_END_DATE}"
      ;;
    ungrib)
      mkdir -p "${_PRE_ROOT}/wps_run/log"
      jid="$(_sbatch "${_PRE_ROOT}/wps_run/slurm_run_ungrib.bash")"
      _LAST_WPS_DEP="${jid}"
      ;;
    metgrid)
      mkdir -p "${_PRE_ROOT}/wps_run/log"
      local dep=()
      [[ -n "${_LAST_WPS_DEP}" ]] && dep=(--dependency="afterok:${_LAST_WPS_DEP}")
      jid="$(_sbatch "${_PRE_ROOT}/wps_run/slurm_run_metgrid.bash" "${dep[@]}")"
      _LAST_WPS_DEP="${jid}"
      ;;
    real)
      mkdir -p "${_PRE_ROOT}/wps_run/log"
      local dep=()
      [[ -n "${_LAST_WPS_DEP}" ]] && dep=(--dependency="afterok:${_LAST_WPS_DEP}")
      jid="$(_sbatch "${_PRE_ROOT}/wps_run/slurm_run_real.bash" "${dep[@]}")"
      _LAST_WPS_DEP="${jid}"
      ;;
    swan)
      jid="$(_sbatch "${_PRE_ROOT}/get_swan_bry/slurm_make_swan_bc.bash")"
      ;;
    roms-a0)
      mkdir -p "${_PRE_ROOT}/get_roms_icbc/log"
      local script
      if [[ "${DAY1}" -eq 1 ]]; then
        script="${_PRE_ROOT}/get_roms_icbc/slurm_run_ocnA0_day1.bash"
      else
        script="${_PRE_ROOT}/get_roms_icbc/slurm_run_ocnA0_par.bash"
      fi
      jid="$(_sbatch "${script}")"
      ;;
    roms-gcawo)
      mkdir -p "${_PRE_ROOT}/get_roms_icbc/log"
      local script extra=()
      if [[ "${DAY1}" -eq 1 ]]; then
        script="${_PRE_ROOT}/get_roms_icbc/slurm_run_ocnGcawo_day1.bash"
      else
        script="${_PRE_ROOT}/get_roms_icbc/slurm_run_ocnGcawo_par.bash"
        # Override array length to match date window
        extra=(--array="0-${_ARRAY_MAX}%8")
      fi
      jid="$(_sbatch "${script}" "${extra[@]}")"
      ;;
    *)
      echo "ERROR: unhandled step ${step}" >&2
      exit 1
      ;;
  esac
}

for step in "${_STEPS[@]}"; do
  _run_step "${step}"
done

_wait_jobs

echo "[preprocess] done"
