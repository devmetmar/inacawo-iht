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
#   ./run_preprocess.bash --start 20251231 --end 20260105 --stage roms --day1
#     → ROMS day1 for 20251231, then *_par for 20260101..20260105
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
  --end YYYYMMDD            End date = last hindcast day label (inclusive).
                            By default also prepares end+1 (12Z→12Z window
                            needs tomorrow's forcing). See --exact-dates.

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
  --day1                    ROMS: first day of --start..--end uses day1 scripts;
                            remaining days use continuing (*_par) scripts
                            (same split as run_hindcast --day1). If start==end,
                            only that day is day1. Continuing slice includes
                            the auto end+1 day when padding is on.
  --exact-dates             Do not extend --end by +1 day. Use when repairing a
                            single calendar day (e.g. only the padding day).
  --glorys-product NAME     reanalysis (default) | interim
  --overwrite               Re-download even if outputs already exist and validate
  --dry-run                 Print commands only
  --wait                    Wait for SLURM jobs (default)
  --no-wait                 Submit SLURM jobs and exit (WPS chained via aftercorr)
  --partition NAME          Slurm partition (default: auto — HDCAST if allowed, else DEV1)
  --no-log                  Do not write $WORK_BASE/logs/ (default: auto-log)
  -v, --verbose             Also mirror log to this terminal (default: quiet)
  -h, --help                Show this help

Date semantics (aligned with run_hindcast):
  Each hindcast day D runs D 12Z → D+1 12Z, so ROMS/SWAN/WPS need products for
  D and D+1. Default: effective range is --start..(--end + 1 day). Same --end
  as run_hindcast is enough; no manual +1. Pass --exact-dates to disable.

Download behaviour:
  Default: skip a download step when all expected outputs for the effective
  --start..--end already exist and validate (NetCDF via ncdump -h; GRIB via
  wgrib2/grib_ls or GRIB magic bytes). Pass --overwrite to force re-download.

SLURM behaviour (wps / swan / roms):
  Per-day Slurm arrays for ungrib/metgrid/real/swan/roms-gcawo (days are
  independent within a stage). Stages still run ungrib → metgrid → real.
  Default: submit → wait for each array → validate products.
  --no-wait: fire-and-forget; WPS uses aftercorr so day i waits on day i only.

Logs (default, under iht repo):
  $WORK_BASE/logs/preprocess/preprocess_<start>_<end>_<stage>_<timestamp>.log
  Terminal prints only the log realpath; monitor with: tail -f <logfile>
  Ctrl+C stops local children and scancels submitted SLURM jobs.
  Each step logs elapsed time; a timing summary is printed at the end.

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
EXACT_DATES=0
GLORYS_PRODUCT="reanalysis"
OVERWRITE=0
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
    --model) MODEL="${2:-}"; shift 2 ;;
    --day1) DAY1=1; shift ;;
    --exact-dates) EXACT_DATES=1; shift ;;
    --glorys-product) GLORYS_PRODUCT="${2:-}"; shift 2 ;;
    --overwrite) OVERWRITE=1; shift ;;
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
_TAIL_PID=""
_SBATCH_JOBS=()
declare -A _JOB_LOGS=()
declare -A _JOB_LABELS=()
declare -A _JOB_DONE=()
_SBATCH_STEP_LABEL=""

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

_iht_stop_tail() {
  if [[ -n "${_TAIL_PID:-}" ]]; then
    kill "${_TAIL_PID}" 2>/dev/null || true
    wait "${_TAIL_PID}" 2>/dev/null || true
    _TAIL_PID=""
  fi
}

_iht_kill_children() {
  _iht_stop_tail
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

# Set IHT_* date exports for a YYYYMMDD..YYYYMMDD window (also _DAYS / _ARRAY_MAX).
_iht_set_dates() {
  local s="$1" e="$2"
  export IHT_START_DATE="${s}"
  export IHT_END_DATE="${e}"
  export IHT_START_DATE_ISO="$(date -d "${s}" +%Y-%m-%d)"
  export IHT_END_DATE_ISO="$(date -d "${e}" +%Y-%m-%d)"
  export IHT_START_DATE_DOT="$(date -d "${s}" +%Y.%m.%d)"
  export IHT_END_DATE_DOT="$(date -d "${e}" +%Y.%m.%d)"
  _DAYS=$(( ( $(date -d "${e}" +%s) - $(date -d "${s}" +%s) ) / 86400 + 1 ))
  _ARRAY_MAX=$((_DAYS - 1))
}

# Requested CLI end (before optional hindcast end+1 pad).
REQUESTED_END="${END}"

_iht_set_dates "${START}" "${END}"

# --day1 split helper (ROMS only; same idea as run_hindcast). Call after END
# is finalized (may include end+1 pad).
_iht_apply_day1_split() {
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
  fi
}
_iht_apply_day1_split

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

# Hindcast day D needs products for D and D+1 (12Z→12Z). Pad --end by +1
# unless --exact-dates (repair a single calendar day).
_iht_steps_need_end_plus_one() {
  local s
  for s in "${_STEPS[@]}"; do
    case "${s}" in
      era5-sfc|era5-pl|era5-waves|glorys|ungrib|metgrid|real|swan|roms-a0|roms-gcawo)
        return 0
        ;;
    esac
  done
  return 1
}

PADDED_END=0
if [[ "${EXACT_DATES}" -eq 0 ]] && _iht_steps_need_end_plus_one; then
  END="$(date -d "${REQUESTED_END} + 1 day" +%Y%m%d)"
  PADDED_END=1
  _iht_set_dates "${START}" "${END}"
  _iht_apply_day1_split
fi

export IHT_OVERWRITE="${OVERWRITE}"

# ---------------------------------------------------------------------------
# Slurm partition: HDCAST if user's account is allowed, else DEV1
# Override: --partition NAME  or  IHT_SLURM_PARTITION=NAME
# ---------------------------------------------------------------------------
# shellcheck source=../src/slurm_partition.bash
source "${_IHT_ROOT}/src/slurm_partition.bash"
_iht_resolve_slurm_partition

echo "[preprocess] ${START} → ${END} (${_DAYS} day(s))"
if [[ "${PADDED_END}" -eq 1 ]]; then
  echo "[preprocess] hindcast window: requested --end=${REQUESTED_END} → also preparing end+1=${END} (use --exact-dates to disable)"
elif [[ "${EXACT_DATES}" -eq 1 ]]; then
  echo "[preprocess] exact-dates=ON (no end+1 pad)"
fi
echo "[preprocess] steps: ${_STEPS[*]}"
if [[ "${DAY1}" -eq 1 ]]; then
  echo "[preprocess] ROMS --day1: day1 slice ${DAY1_START} → ${DAY1_END}"
  if [[ -n "${CONT_START}" ]]; then
    echo "[preprocess] ROMS --day1: continuing slice ${CONT_START} → ${CONT_END}"
  fi
fi
[[ "${DRY_RUN}" -eq 1 ]] && echo "[preprocess] DRY-RUN"
if [[ "${WAIT_JOBS}" -eq 1 ]]; then
  echo "[preprocess] wait=ON (sequential Slurm monitor → SST log; use --no-wait to detach)"
else
  echo "[preprocess] wait=OFF (submit only; WPS uses aftercorr chain)"
fi
if [[ "${OVERWRITE}" -eq 1 ]]; then
  echo "[preprocess] overwrite=ON (force re-download)"
else
  echo "[preprocess] overwrite=OFF (skip valid existing download outputs)"
fi
_iht_log_slurm_partition "[preprocess]"

# ---------------------------------------------------------------------------
# Timing + download skip helpers
# ---------------------------------------------------------------------------
_STEP_TIMES=()   # "label|seconds|status"
_RUN_T0="$(date +%s)"

_iht_fmt_elapsed() {
  local s="${1:-0}"
  (( s < 0 )) && s=0
  local h=$((s / 3600)) m=$(((s % 3600) / 60)) sec=$((s % 60))
  if (( h > 0 )); then
    printf '%dh%02dm%02ds' "${h}" "${m}" "${sec}"
  else
    printf '%dm%02ds' "${m}" "${sec}"
  fi
}

_iht_file_valid() {
  local f="$1"
  [[ -f "${f}" && -s "${f}" ]] || return 1
  case "${f}" in
    *.nc|*.nc4)
      if ! command -v ncdump >/dev/null 2>&1; then
        echo "[warn] ncdump not found; cannot validate ${f}" >&2
        return 1
      fi
      ncdump -h "${f}" >/dev/null 2>&1
      ;;
    *.grib|*.grb|*.grib2)
      if command -v wgrib2 >/dev/null 2>&1; then
        wgrib2 -s "${f}" >/dev/null 2>&1
      elif command -v grib_ls >/dev/null 2>&1; then
        grib_ls "${f}" >/dev/null 2>&1
      else
        # Fallback: GRIB magic + non-trivial size
        local magic sz
        magic="$(head -c 4 "${f}" 2>/dev/null || true)"
        sz="$(stat -c%s "${f}" 2>/dev/null || echo 0)"
        [[ "${magic}" == "GRIB" && "${sz}" -gt 1000 ]]
      fi
      ;;
    *)
      return 1
      ;;
  esac
}

# List YYYYMMDD dates from START..END inclusive (stdout, one per line).
_iht_each_day() {
  local d="${IHT_START_DATE}"
  while [[ "${d}" -le "${IHT_END_DATE}" ]]; do
    echo "${d}"
    d="$(date -d "${d:0:4}-${d:4:2}-${d:6:2} +1 day" +%Y%m%d)"
  done
}

# Return 0 if all expected download outputs for step are present + valid.
_iht_download_outputs_valid() {
  local step="$1"
  local d ymd iso base f1 f2
  local cawo="${CAWO_INPUT:-}"
  [[ -n "${cawo}" ]] || return 1

  case "${step}" in
    era5-sfc)
      while read -r d; do
        base="${cawo}/era5/era5_${d}"
        f1="${base}/era5_surface_part1.grib"
        f2="${base}/era5_surface_part2.grib"
        _iht_file_valid "${f1}" || return 1
        _iht_file_valid "${f2}" || return 1
      done < <(_iht_each_day)
      ;;
    era5-pl)
      while read -r d; do
        base="${cawo}/era5/era5_${d}"
        f1="${base}/era5_pl_part1.grib"
        f2="${base}/era5_pl_part2.grib"
        _iht_file_valid "${f1}" || return 1
        _iht_file_valid "${f2}" || return 1
      done < <(_iht_each_day)
      ;;
    era5-waves)
      while read -r d; do
        base="${cawo}/era5_waves/era5_${d}"
        f1="${base}/era5_waves_part1.grib"
        f2="${base}/era5_waves_part2.grib"
        _iht_file_valid "${f1}" || return 1
        _iht_file_valid "${f2}" || return 1
      done < <(_iht_each_day)
      ;;
    glorys)
      local gdir="${GLORYS_BASE_DIR:-${cawo}/mercator}"
      # Download scripts write under CAWO_INPUT/mercator; prefer that if set.
      [[ -d "${cawo}/mercator" ]] && gdir="${cawo}/mercator"
      while read -r d; do
        iso="$(date -d "${d:0:4}-${d:4:2}-${d:6:2}" +%Y-%m-%d)"
        f1="${gdir}/GLORYS_Reanalysis_LO_${iso}T00:00:00.nc"
        _iht_file_valid "${f1}" || return 1
      done < <(_iht_each_day)
      ;;
    *)
      return 1
      ;;
  esac
  return 0
}

_iht_is_download_step() {
  case "$1" in
    era5-sfc|era5-pl|era5-waves|glorys) return 0 ;;
    *) return 1 ;;
  esac
}

_iht_record_time() {
  local label="$1" secs="$2" status="$3"
  _STEP_TIMES+=("${label}|${secs}|${status}")
  echo "[time] ${label}: $(_iht_fmt_elapsed "${secs}") (${status})" >&2
}

_iht_print_timing_summary() {
  local total=$(( $(date +%s) - _RUN_T0 ))
  local entry label secs status
  echo "[preprocess] timing summary:"
  for entry in "${_STEP_TIMES[@]:-}"; do
    [[ -z "${entry}" ]] && continue
    IFS='|' read -r label secs status <<< "${entry}"
    printf '  %-28s  %10s  %s\n' "${label}" "$(_iht_fmt_elapsed "${secs}")" "${status}"
  done
  echo "  ----------------------------------------"
  printf '  %-28s  %10s\n' "TOTAL" "$(_iht_fmt_elapsed "${total}")"
}

# ---------------------------------------------------------------------------
# Run helpers
# ---------------------------------------------------------------------------
_run_local() {
  local desc="$1"; shift
  local rc=0 t0 t1 elapsed
  echo "[run] ${desc}" >&2
  echo "      $*" >&2
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    _iht_record_time "${desc}" 0 "dry-run"
    return 0
  fi
  t0="$(date +%s)"
  # New process group so Ctrl+C can kill the whole subtree (python, etc.)
  set -m
  "$@" &
  _CHILD_PID=$!
  set +m
  wait "${_CHILD_PID}" || rc=$?
  _CHILD_PID=""
  t1="$(date +%s)"
  elapsed=$((t1 - t0))
  if [[ "${rc}" -eq 0 ]]; then
    _iht_record_time "${desc}" "${elapsed}" "ok"
  else
    _iht_record_time "${desc}" "${elapsed}" "FAILED(rc=${rc})"
  fi
  return "${rc}"
}

_skip_local() {
  local desc="$1"
  echo "[skip] ${desc} (outputs valid; pass --overwrite to re-download)" >&2
  _iht_record_time "${desc}" 0 "skipped"
}

# Resolve expected Slurm stdout path from #SBATCH --output= (relative → script dir).
_sbatch_resolve_log() {
  local script="$1" jid="$2" script_dir="$3"
  local out_pat
  out_pat="$(grep -E '^#SBATCH[[:space:]]+--output=' "${script}" 2>/dev/null \
    | head -n1 | sed -E 's/^#SBATCH[[:space:]]+--output=//' || true)"
  if [[ -z "${out_pat}" ]]; then
    echo "${script_dir}/slurm-${jid}.out"
    return 0
  fi
  out_pat="${out_pat//%j/${jid}}"
  out_pat="${out_pat//%J/${jid}}"
  out_pat="${out_pat//%A/${jid}}"
  # Array jobs: follow task 0 as the representative live log
  out_pat="${out_pat//%a/0}"
  if [[ "${out_pat}" != /* ]]; then
    out_pat="${script_dir}/${out_pat}"
  fi
  echo "${out_pat}"
}

# Submit sbatch. Sets _LAST_SBATCH_JID (never call via $() — must not run in a subshell
# or job metadata / scancel tracking is lost). Label via _SBATCH_STEP_LABEL.
# Uses --chdir so relative #SBATCH --output lands under the script directory.

_sbatch() {
  local script="$1"; shift
  local extra=("$@")
  local script_dir label out jid
  script_dir="$(cd "$(dirname "${script}")" && pwd)"
  label="${_SBATCH_STEP_LABEL:-$(basename "${script}")}"
  _LAST_SBATCH_JID=""

  local export_list="ALL,IHT_START_DATE=${IHT_START_DATE},IHT_END_DATE=${IHT_END_DATE}"
  export_list+=",IHT_START_DATE_ISO=${IHT_START_DATE_ISO},IHT_END_DATE_ISO=${IHT_END_DATE_ISO}"
  export_list+=",IHT_START_DATE_DOT=${IHT_START_DATE_DOT},IHT_END_DATE_DOT=${IHT_END_DATE_DOT}"

  local cmd=(sbatch --chdir="${script_dir}" --partition="${IHT_SLURM_PARTITION}" \
    --export="${export_list}" "${extra[@]}" "${script}")
  echo "[sbatch] ${cmd[*]}"
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    # Unique dry-run ids so associative maps do not collide across steps
    jid="DRYRUN_${label}_$$_${#_SBATCH_JOBS[@]}"
    _SBATCH_JOBS+=("${jid}")
    _JOB_LABELS["${jid}"]="${label}"
    _JOB_LOGS["${jid}"]="${script_dir}/dry-run.log"
    _LAST_SBATCH_JID="${jid}"
    return 0
  fi
  out="$("${cmd[@]}")"
  echo "${out}"
  jid="$(echo "${out}" | awk '{print $NF}')"
  _SBATCH_JOBS+=("${jid}")
  _JOB_LABELS["${jid}"]="${label}"
  _JOB_LOGS["${jid}"]="$(_sbatch_resolve_log "${script}" "${jid}" "${script_dir}")"
  _LAST_SBATCH_JID="${jid}"
  echo "[preprocess] ${label} submitted job=${jid}"
  echo "[preprocess] ${label} slurm log → ${_JOB_LOGS[${jid}]}"
}

# Block until one Slurm job finishes; stream its log into the preprocess SST log.
_wait_one_job() {
  local jid="$1"
  local label="${_JOB_LABELS[${jid}]:-${jid}}"
  local logfile="${_JOB_LOGS[${jid}]:-}"
  local t0 t1 state reason elapsed
  local poll=15
  local last_status=""

  t0="$(date +%s)"
  echo "[preprocess] === monitor ${label} job=${jid} ==="
  [[ -n "${logfile}" ]] && echo "[preprocess] following → ${logfile}"

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    _iht_record_time "${label}" 0 "dry-run"
    _JOB_DONE["${jid}"]=1
    return 0
  fi

  while true; do
    state="$(squeue -h -j "${jid}" -o '%T' 2>/dev/null | head -n1 | tr -d ' ' || true)"
    if [[ -z "${state}" ]]; then
      break
    fi
    case "${state}" in
      PENDING)
        reason="$(squeue -h -j "${jid}" -o '%r' 2>/dev/null | head -n1 || true)"
        if [[ "${last_status}" != "PENDING:${reason}" ]]; then
          echo "[preprocess] ${label} ${jid}: PENDING (${reason})"
          last_status="PENDING:${reason}"
        fi
        ;;
      RUNNING|COMPLETING|CONFIGURING|STAGE_OUT)
        if [[ "${last_status}" != "RUNNING" ]]; then
          echo "[preprocess] ${label} ${jid}: ${state}"
          last_status="RUNNING"
        fi
        if [[ -n "${logfile}" && -z "${_TAIL_PID}" ]]; then
          [[ -f "${logfile}" ]] || sleep 2
          if [[ -f "${logfile}" ]]; then
            echo "[preprocess] --- live ${logfile} ---"
            tail -n +1 -F "${logfile}" 2>/dev/null &
            _TAIL_PID=$!
          fi
        fi
        ;;
      FAILED|CANCELLED|TIMEOUT|NODE_FAIL|OUT_OF_MEMORY|PREEMPTED|BOOT_FAIL)
        _iht_stop_tail
        echo "ERROR: ${label} job ${jid} state=${state}" >&2
        if [[ -n "${logfile}" && -f "${logfile}" ]]; then
          echo "--- last 80 lines of ${logfile} ---"
          tail -n 80 "${logfile}"
        fi
        return 1
        ;;
      *)
        if [[ "${last_status}" != "${state}" ]]; then
          echo "[preprocess] ${label} ${jid}: ${state}"
          last_status="${state}"
        fi
        ;;
    esac
    sleep "${poll}"
  done

  _iht_stop_tail

  if command -v sacct >/dev/null 2>&1; then
    # Brief settle for accounting (array jobs may have many task lines)
    sleep 2
    local bad=""
    while IFS= read -r state; do
      state="$(echo "${state}" | tr -d ' ')"
      [[ -z "${state}" || "${state}" == "COMPLETED" ]] && continue
      bad="${state}"
      break
    done < <(sacct -n -X -j "${jid}" -o State --parsable2 2>/dev/null || true)
    if [[ -n "${bad}" ]]; then
      echo "ERROR: ${label} job ${jid} sacct state=${bad}" >&2
      if [[ -n "${logfile}" && -f "${logfile}" ]]; then
        echo "--- last 80 lines of ${logfile} ---"
        tail -n 80 "${logfile}"
      fi
      return 1
    fi
  fi

  if [[ -n "${logfile}" && -f "${logfile}" ]]; then
    echo "[preprocess] --- ${label} finished; last 40 lines ---"
    tail -n 40 "${logfile}"
  fi

  t1="$(date +%s)"
  elapsed=$((t1 - t0))
  _JOB_DONE["${jid}"]=1
  _iht_record_time "${label}" "${elapsed}" "ok"
  echo "[preprocess] ${label} job ${jid} COMPLETED ($(_iht_fmt_elapsed "${elapsed}"))"
  return 0
}

# Submit then optionally wait (default). Relies on _sbatch setting _LAST_SBATCH_JID.
_LAST_SBATCH_JID=""
_sbatch_step() {
  local label="$1"; shift
  local script="$1"; shift
  local extra=("$@")
  local t0 t1
  _SBATCH_STEP_LABEL="${label}"
  t0="$(date +%s)"
  _sbatch "${script}" "${extra[@]}"
  if [[ -z "${_LAST_SBATCH_JID}" ]]; then
    echo "ERROR: sbatch did not set job id for ${label}" >&2
    exit 1
  fi
  if [[ "${WAIT_JOBS}" -eq 1 ]]; then
    _wait_one_job "${_LAST_SBATCH_JID}" || exit 1
  else
    t1="$(date +%s)"
    _iht_record_time "${label} (sbatch ${_LAST_SBATCH_JID})" "$((t1 - t0))" "submitted"
  fi
}

_wait_jobs() {
  if [[ "${WAIT_JOBS}" -ne 1 || "${DRY_RUN}" -eq 1 ]]; then
    return 0
  fi
  if [[ "${#_SBATCH_JOBS[@]}" -eq 0 ]]; then
    return 0
  fi
  local jid
  for jid in "${_SBATCH_JOBS[@]}"; do
    [[ -n "${_JOB_DONE[${jid}]+x}" ]] && continue
    _wait_one_job "${jid}" || exit 1
  done
}

# Track last WPS array job for aftercorr chain within this invocation
_LAST_WPS_DEP=""

# DEV1: shrink multi-node IB jobs to 1 node (mlx/ib0 fails on DEV1).
_iht_dev1_mpi_overrides() {
  if [[ "${IHT_SLURM_PARTITION}" == "DEV1" ]]; then
    echo --nodes=1 --ntasks-per-node=32
  fi
}

# Ensure LO expects $LO_DATA/grids/cawo/{grid.nc,S_COORDINATE_INFO.csv,...}
# by linking from shared $GRID_DATA (used by ocnA0 / LiveOcean).
_iht_seed_lo_grid() {
  local lo_data="${LO_DATA:-${CAWO_INPUT:-}/LO_data}"
  local grid_src="${GRID_DATA:-}"
  local dest="${lo_data}/grids/cawo"
  local f linked=0

  if [[ -z "${grid_src}" || ! -d "${grid_src}" ]]; then
    echo "ERROR: GRID_DATA unset or missing (${grid_src:-})" >&2
    return 1
  fi
  if [[ ! -f "${grid_src}/grid.nc" ]]; then
    echo "ERROR: ${grid_src}/grid.nc not found (required for ROMS ocnA0)" >&2
    return 1
  fi
  mkdir -p "${dest}"
  for f in grid.nc S_COORDINATE_INFO.csv XY_COORDINATE_INFO.csv nudgcoef.nc; do
    if [[ -e "${grid_src}/${f}" ]]; then
      if [[ ! -e "${dest}/${f}" ]]; then
        ln -sfn "${grid_src}/${f}" "${dest}/${f}"
        echo "[preprocess] linked ${dest}/${f} → ${grid_src}/${f}"
        linked=1
      fi
    fi
  done
  if [[ ! -e "${dest}/grid.nc" ]]; then
    echo "ERROR: failed to place ${dest}/grid.nc" >&2
    return 1
  fi
  if [[ "${linked}" -eq 0 ]]; then
    echo "[preprocess] LO grid OK: ${dest}/grid.nc"
  fi
  return 0
}

# Seed $LO_DATA/varinfo/varinfo.yaml for zrfun.get_varinfo (ocnA0 / ocnGcawo).
# Source: $LO_ROMS_VARINFO or $LO_ROMS_SOURCE_ALT/varinfo/varinfo.yaml.
_iht_seed_lo_varinfo() {
  local lo_data="${LO_DATA:-${CAWO_INPUT:-}/LO_data}"
  local dest_dir="${lo_data}/varinfo"
  local dest="${dest_dir}/varinfo.yaml"
  local src=""

  if [[ -n "${LO_ROMS_VARINFO:-}" && -f "${LO_ROMS_VARINFO}" ]]; then
    src="${LO_ROMS_VARINFO}"
  elif [[ -n "${LO_ROMS_SOURCE_ALT:-}" && -f "${LO_ROMS_SOURCE_ALT}/varinfo/varinfo.yaml" ]]; then
    src="${LO_ROMS_SOURCE_ALT}/varinfo/varinfo.yaml"
  elif [[ -f /scratch/cawohdcst_ft/home/cawohdcst/LO_roms_source_alt/varinfo/varinfo.yaml ]]; then
    src="/scratch/cawohdcst_ft/home/cawohdcst/LO_roms_source_alt/varinfo/varinfo.yaml"
  fi

  if [[ -z "${src}" ]]; then
    echo "ERROR: varinfo.yaml not found (set LO_ROMS_VARINFO or LO_ROMS_SOURCE_ALT)" >&2
    return 1
  fi
  mkdir -p "${dest_dir}"
  if [[ ! -e "${dest}" ]]; then
    ln -sfn "${src}" "${dest}"
    echo "[preprocess] linked ${dest} → ${src}"
  else
    echo "[preprocess] LO varinfo OK: ${dest}"
  fi
  return 0
}

_iht_seed_lo_paths() {
  _iht_seed_lo_grid || return 1
  _iht_seed_lo_varinfo || return 1
}

# Verify WPS products exist for the date window (catches Slurm COMPLETED + silent fail).
_iht_validate_wps_step() {
  local step="$1"
  local wps="${WPS_RUN_DIR:-}"
  local d missing=0
  [[ -n "${wps}" ]] || { echo "ERROR: WPS_RUN_DIR unset" >&2; return 1; }
  [[ "${DRY_RUN}" -eq 1 ]] && return 0

  while read -r d; do
    case "${step}" in
      ungrib)
        if ! compgen -G "${wps}/era5_${d}/ungrib/FILE:*" >/dev/null; then
          echo "ERROR: ungrib missing FILE:* for ${d} under ${wps}/era5_${d}/ungrib" >&2
          missing=1
        fi
        ;;
      metgrid)
        if ! compgen -G "${wps}/era5_${d}/metgrid/met_em.d01*" >/dev/null; then
          echo "ERROR: metgrid missing met_em.d01* for ${d}" >&2
          missing=1
        fi
        ;;
      real)
        if [[ ! -f "${wps}/era5_${d}/real/wrfinput_d01" ]]; then
          echo "ERROR: real missing wrfinput_d01 for ${d}" >&2
          missing=1
        fi
        ;;
    esac
  done < <(_iht_each_day)

  if [[ "${missing}" -ne 0 ]]; then
    echo "ERROR: ${step} reported COMPLETED but required products are missing" >&2
    return 1
  fi
  echo "[preprocess] ${step} products OK for ${IHT_START_DATE}..${IHT_END_DATE}"
  return 0
}

_run_step() {
  local step="$1"
  local jid="" t0 t1

  # Download steps: skip when outputs already valid (unless --overwrite)
  if _iht_is_download_step "${step}"; then
    local dlabel="${step}"
    if [[ "${step}" == "glorys" ]]; then
      dlabel="glorys (${GLORYS_PRODUCT})"
    fi
    if [[ "${OVERWRITE}" -eq 0 && "${DRY_RUN}" -eq 0 ]]; then
      if _iht_download_outputs_valid "${step}"; then
        _skip_local "${dlabel}"
        return 0
      fi
    fi
  fi

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
      # Per-day Slurm array (days independent). Concurrency capped at 16.
      mkdir -p "${_PRE_ROOT}/wps_run/log"
      _sbatch_step "ungrib" "${_PRE_ROOT}/wps_run/slurm_run_ungrib.bash" \
        --array="0-${_ARRAY_MAX}%16"
      _LAST_WPS_DEP="${_LAST_SBATCH_JID}"
      if [[ "${WAIT_JOBS}" -eq 1 && "${DRY_RUN}" -eq 0 ]]; then
        _iht_validate_wps_step ungrib || exit 1
      fi
      ;;
    metgrid)
      mkdir -p "${_PRE_ROOT}/wps_run/log"
      local dep=() extra=()
      # --no-wait: aftercorr so task i waits for ungrib task i; with --wait stages are serial
      if [[ "${WAIT_JOBS}" -eq 0 && -n "${_LAST_WPS_DEP}" ]]; then
        dep=(--dependency="aftercorr:${_LAST_WPS_DEP}")
      fi
      # shellcheck disable=SC2207
      extra=( $(_iht_dev1_mpi_overrides) )
      _sbatch_step "metgrid" "${_PRE_ROOT}/wps_run/slurm_run_metgrid.bash" \
        --array="0-${_ARRAY_MAX}%4" "${dep[@]}" "${extra[@]}"
      _LAST_WPS_DEP="${_LAST_SBATCH_JID}"
      if [[ "${WAIT_JOBS}" -eq 1 && "${DRY_RUN}" -eq 0 ]]; then
        _iht_validate_wps_step metgrid || exit 1
      fi
      ;;
    real)
      mkdir -p "${_PRE_ROOT}/wps_run/log"
      local dep=() extra=()
      if [[ "${WAIT_JOBS}" -eq 0 && -n "${_LAST_WPS_DEP}" ]]; then
        dep=(--dependency="aftercorr:${_LAST_WPS_DEP}")
      fi
      # shellcheck disable=SC2207
      extra=( $(_iht_dev1_mpi_overrides) )
      _sbatch_step "real" "${_PRE_ROOT}/wps_run/slurm_run_real.bash" \
        --array="0-${_ARRAY_MAX}%2" "${dep[@]}" "${extra[@]}"
      _LAST_WPS_DEP="${_LAST_SBATCH_JID}"
      if [[ "${WAIT_JOBS}" -eq 1 && "${DRY_RUN}" -eq 0 ]]; then
        _iht_validate_wps_step real || exit 1
      fi
      ;;
    swan)
      # Per-day array; independent of WPS (needs era5-waves only)
      mkdir -p "${_PRE_ROOT}/get_swan_bry/log"
      _sbatch_step "swan" "${_PRE_ROOT}/get_swan_bry/slurm_make_swan_bc.bash" \
        --array="0-${_ARRAY_MAX}%8"
      ;;
    roms-a0)
      mkdir -p "${_PRE_ROOT}/get_roms_icbc/log"
      _iht_seed_lo_paths || exit 1
      if [[ "${DAY1}" -eq 1 ]]; then
        # First calendar day: day1 / "new" init
        _iht_set_dates "${DAY1_START}" "${DAY1_END}"
        _sbatch_step "roms-a0-day1" "${_PRE_ROOT}/get_roms_icbc/slurm_run_ocnA0_day1.bash"
        if [[ -n "${CONT_START}" ]]; then
          _iht_set_dates "${CONT_START}" "${CONT_END}"
          _sbatch_step "roms-a0-cont" "${_PRE_ROOT}/get_roms_icbc/slurm_run_ocnA0_par.bash"
        fi
        _iht_set_dates "${START}" "${END}"
      else
        _sbatch_step "roms-a0" "${_PRE_ROOT}/get_roms_icbc/slurm_run_ocnA0_par.bash"
      fi
      ;;
    roms-gcawo)
      mkdir -p "${_PRE_ROOT}/get_roms_icbc/log"
      _iht_seed_lo_paths || exit 1
      if [[ "${DAY1}" -eq 1 ]]; then
        _iht_set_dates "${DAY1_START}" "${DAY1_END}"
        _sbatch_step "roms-gcawo-day1" "${_PRE_ROOT}/get_roms_icbc/slurm_run_ocnGcawo_day1.bash"
        if [[ -n "${CONT_START}" ]]; then
          _iht_set_dates "${CONT_START}" "${CONT_END}"
          _sbatch_step "roms-gcawo-cont" \
            "${_PRE_ROOT}/get_roms_icbc/slurm_run_ocnGcawo_par.bash" \
            --array="0-${_ARRAY_MAX}%8"
        fi
        _iht_set_dates "${START}" "${END}"
      else
        _sbatch_step "roms-gcawo" \
          "${_PRE_ROOT}/get_roms_icbc/slurm_run_ocnGcawo_par.bash" \
          --array="0-${_ARRAY_MAX}%8"
      fi
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

_iht_print_timing_summary
echo "[preprocess] done"
