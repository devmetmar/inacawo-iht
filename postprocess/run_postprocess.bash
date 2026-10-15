#!/bin/bash
# InaCAWO postprocess entrypoint — regrid hindcast history to CAWO LL0.025.
#
# Usage:
#   ./run_postprocess.bash --start YYYYMMDD --end YYYYMMDD [options]
#
# Examples:
#   ./run_postprocess.bash --start 19950101 --end 19950105
#   ./run_postprocess.bash --start 19950101 --end 19950105 --stage roms2d
#   ./run_postprocess.bash --start 19950101 --end 19950105 --stage wrf --dry-run
#
set -euo pipefail

_POST_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_IHT_ROOT="$(cd "${_POST_ROOT}/.." && pwd)"
_ORIG_ARGS=("$@")

_CANONICAL_ORDER=(roms2d roms3d wrf2d wrf3d)

usage() {
  cat <<'EOF'
Usage: run_postprocess.bash --start YYYYMMDD --end YYYYMMDD [options]

Required:
  --start YYYYMMDD          Start date (inclusive) = hindcast day label
  --end YYYYMMDD            End date (inclusive). No end+1 padding
                            (postprocess consumes completed days as labeled).

Stage selection:
  --stage LIST              Comma-separated aliases and/or atomic steps
                            (default: all)

Atomic steps:
  roms2d  roms3d  wrf2d  wrf3d

Aliases:
  roms      -> roms2d,roms3d
  wrf       -> wrf2d,wrf3d
  all       -> roms2d,roms3d,wrf2d,wrf3d  (default)

Options:
  --dry-run                 Print sbatch commands only
  --wait                    Wait for SLURM jobs (default)
  --no-wait                 Submit SLURM jobs and exit
  --partition NAME          Slurm partition (default: auto — HDCAST if allowed,
                            else DEV1)
  --no-log                  Do not write $WORK_BASE/logs/ (default: auto-log)
  -v, --verbose             Also mirror log to this terminal (default: quiet)
  -h, --help                Show this help

Logs (default, under iht repo):
  $WORK_BASE/logs/postprocess/postprocess_<start>_<end>_<stage>_<timestamp>.log
  Terminal prints only the log realpath; monitor with: tail -f <logfile>
  Ctrl+C scancels jobs submitted in that run.
EOF
}

# ---------------------------------------------------------------------------
# Arg parse
# ---------------------------------------------------------------------------
START=""
END=""
STAGE="all"
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

if ! date -d "${START}" >/dev/null 2>&1; then
  echo "ERROR: invalid --start ${START} (want YYYYMMDD)" >&2
  exit 2
fi
if ! date -d "${END}" >/dev/null 2>&1; then
  echo "ERROR: invalid --end ${END} (want YYYYMMDD)" >&2
  exit 2
fi
if [[ "${START}" -gt "${END}" ]]; then
  echo "ERROR: --start ${START} > --end ${END}" >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# Env bootstrap
# ---------------------------------------------------------------------------
if [[ -f "${_IHT_ROOT}/setup_env.bash" ]]; then
  # shellcheck disable=SC1091
  source "${_IHT_ROOT}/setup_env.bash"
else
  echo "ERROR: missing ${_IHT_ROOT}/setup_env.bash" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Auto-log → $WORK_BASE/logs/postprocess/
# ---------------------------------------------------------------------------
IHT_POSTPROCESS_LOG=""
_TAIL_PID=""
_SBATCH_JOBS=()
declare -A _JOB_LOGS=()
declare -A _JOB_LABELS=()
declare -A _JOB_DONE=()
_SBATCH_STEP_LABEL=""

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

_iht_stop_tail() {
  if [[ -n "${_TAIL_PID:-}" ]]; then
    kill "${_TAIL_PID}" 2>/dev/null || true
    wait "${_TAIL_PID}" 2>/dev/null || true
    _TAIL_PID=""
  fi
}

_iht_scancel_jobs() {
  local jid
  for jid in "${_SBATCH_JOBS[@]:-}"; do
    [[ -z "${jid}" || "${jid}" == DRYRUN_* ]] && continue
    scancel "${jid}" 2>/dev/null || true
  done
}

_iht_on_interrupt() {
  local sig="${1:-INT}"
  trap - INT TERM EXIT
  echo "[postprocess] caught SIG${sig}; scancel…" || true
  _iht_stop_tail
  _iht_scancel_jobs
  echo "[postprocess] interrupted rc=130 at $(date -Is)" || true
  exit 130
}

_iht_on_exit() {
  local rc=$?
  if [[ "${rc}" -ne 130 ]]; then
    echo "[postprocess] finished rc=${rc} at $(date -Is)"
    if [[ -n "${IHT_POSTPROCESS_LOG}" ]]; then
      echo "[postprocess] log → ${IHT_POSTPROCESS_LOG}"
    fi
  fi
}

if [[ "${NO_LOG}" -eq 0 ]]; then
  export IHT_LOG_DIR="${IHT_LOG_DIR:-${WORK_BASE}/logs}"
  _LOG_DIR="${IHT_LOG_DIR}/postprocess"
  mkdir -p "${_LOG_DIR}"
  _TS="$(date +%Y%m%d_%H%M%S)"
  _TAG="$(echo "${STAGE}" | tr ',/ ' '___' | tr -cd 'A-Za-z0-9._-')"
  [[ -z "${_TAG}" ]] && _TAG="run"
  IHT_POSTPROCESS_LOG="$(_iht_realpath_log "${_LOG_DIR}/postprocess_${START}_${END}_${_TAG}_${_TS}.log")"
  export IHT_POSTPROCESS_LOG

  exec 3>&1 4>&2
  echo "${IHT_POSTPROCESS_LOG}" >&3
  if [[ "${VERBOSE}" -eq 1 ]]; then
    exec > >(tee -a "${IHT_POSTPROCESS_LOG}" >&3) 2>&1
  else
    exec >>"${IHT_POSTPROCESS_LOG}" 2>&1
  fi
  echo "[postprocess] log started $(date -Is) pid=$$"
  echo "[postprocess] argv: ${_POST_ROOT}/run_postprocess.bash ${_ORIG_ARGS[*]}"
  echo "[postprocess] WORK_BASE=${WORK_BASE} IHT_LOG_DIR=${IHT_LOG_DIR}"
  echo "[postprocess] monitor: tail -f ${IHT_POSTPROCESS_LOG}"
  trap '_iht_on_interrupt INT' INT
  trap '_iht_on_interrupt TERM' TERM
  trap _iht_on_exit EXIT
else
  trap '_iht_on_interrupt INT' INT
  trap '_iht_on_interrupt TERM' TERM
fi

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

_iht_set_dates "${START}" "${END}"

# ---------------------------------------------------------------------------
# Stage expand
# ---------------------------------------------------------------------------
_expand_token() {
  local t="$1"
  case "$t" in
    all) echo "roms2d roms3d wrf2d wrf3d" ;;
    roms) echo "roms2d roms3d" ;;
    wrf) echo "wrf2d wrf3d" ;;
    roms2d|roms3d|wrf2d|wrf3d) echo "$t" ;;
    *)
      echo "ERROR: unknown stage token: $t" >&2
      return 1
      ;;
  esac
}

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

# ---------------------------------------------------------------------------
# Slurm partition
# ---------------------------------------------------------------------------
# shellcheck source=../src/slurm_partition.bash
source "${_IHT_ROOT}/src/slurm_partition.bash"
_iht_resolve_slurm_partition

echo "[postprocess] ${START} → ${END} (${_DAYS} day(s), array=0-${_ARRAY_MAX})"
echo "[postprocess] steps: ${_STEPS[*]}"
echo "[postprocess] CAWO_OUTPUT=${CAWO_OUTPUT}"
echo "[postprocess] CAWO_POST=${CAWO_POST}"
[[ "${DRY_RUN}" -eq 1 ]] && echo "[postprocess] DRY-RUN"
if [[ "${WAIT_JOBS}" -eq 1 ]]; then
  echo "[postprocess] wait=ON (sequential Slurm monitor → SST log; use --no-wait to detach)"
else
  echo "[postprocess] wait=OFF (submit only)"
fi
_iht_log_slurm_partition "[postprocess]"

# ---------------------------------------------------------------------------
# Timing helpers
# ---------------------------------------------------------------------------
_STEP_TIMES=()

_iht_fmt_elapsed() {
  local secs="$1"
  printf '%dm%02ds' $((secs / 60)) $((secs % 60))
}

_iht_record_time() {
  local label="$1" secs="$2" status="$3"
  _STEP_TIMES+=("${label}|${secs}|${status}")
  echo "[time] ${label}: $(_iht_fmt_elapsed "${secs}") (${status})" >&2
}

_iht_print_timing_summary() {
  local total=0 entry label secs status
  echo ""
  echo "[postprocess] timing summary"
  printf '  %-28s  %10s  %s\n' "STEP" "ELAPSED" "STATUS"
  for entry in "${_STEP_TIMES[@]:-}"; do
    IFS='|' read -r label secs status <<< "${entry}"
    printf '  %-28s  %10s  %s\n' "${label}" "$(_iht_fmt_elapsed "${secs}")" "${status}"
    total=$((total + secs))
  done
  printf '  %-28s  %10s\n' "TOTAL" "$(_iht_fmt_elapsed "${total}")"
}

# ---------------------------------------------------------------------------
# sbatch helpers (mirrors preprocess)
# ---------------------------------------------------------------------------
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
  out_pat="${out_pat//%a/0}"
  if [[ "${out_pat}" != /* ]]; then
    out_pat="${script_dir}/${out_pat}"
  fi
  echo "${out_pat}"
}

_LAST_SBATCH_JID=""
_sbatch() {
  local script="$1"; shift
  local extra=("$@")
  local script_dir label out jid
  script_dir="$(cd "$(dirname "${script}")" && pwd)"
  label="${_SBATCH_STEP_LABEL:-$(basename "${script}")}"
  _LAST_SBATCH_JID=""
  mkdir -p "${script_dir}/log"

  local export_list="ALL,IHT_START_DATE=${IHT_START_DATE},IHT_END_DATE=${IHT_END_DATE}"
  export_list+=",IHT_START_DATE_ISO=${IHT_START_DATE_ISO},IHT_END_DATE_ISO=${IHT_END_DATE_ISO}"
  export_list+=",IHT_START_DATE_DOT=${IHT_START_DATE_DOT},IHT_END_DATE_DOT=${IHT_END_DATE_DOT}"

  local cmd=(sbatch --chdir="${script_dir}" --partition="${IHT_SLURM_PARTITION}" \
    --export="${export_list}" "${extra[@]}" "${script}")
  echo "[sbatch] ${cmd[*]}"
  if [[ "${DRY_RUN}" -eq 1 ]]; then
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
  echo "[postprocess] ${label} submitted job=${jid}"
  echo "[postprocess] ${label} slurm log → ${_JOB_LOGS[${jid}]}"
}

_wait_one_job() {
  local jid="$1"
  local label="${_JOB_LABELS[${jid}]:-${jid}}"
  local logfile="${_JOB_LOGS[${jid}]:-}"
  local t0 t1 state reason elapsed
  local poll=15
  local last_status=""

  t0="$(date +%s)"
  echo "[postprocess] === monitor ${label} job=${jid} ==="
  [[ -n "${logfile}" ]] && echo "[postprocess] following → ${logfile}"

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
          echo "[postprocess] ${label} ${jid}: PENDING (${reason})"
          last_status="PENDING:${reason}"
        fi
        ;;
      RUNNING|COMPLETING|CONFIGURING|STAGE_OUT)
        if [[ "${last_status}" != "RUNNING" ]]; then
          echo "[postprocess] ${label} ${jid}: ${state}"
          last_status="RUNNING"
        fi
        if [[ -n "${logfile}" && -z "${_TAIL_PID}" ]]; then
          [[ -f "${logfile}" ]] || sleep 2
          if [[ -f "${logfile}" ]]; then
            echo "[postprocess] --- live ${logfile} ---"
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
          echo "[postprocess] ${label} ${jid}: ${state}"
          last_status="${state}"
        fi
        ;;
    esac
    sleep "${poll}"
  done

  _iht_stop_tail

  if command -v sacct >/dev/null 2>&1; then
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
    echo "[postprocess] --- ${label} finished; last 40 lines ---"
    tail -n 40 "${logfile}"
  fi

  t1="$(date +%s)"
  elapsed=$((t1 - t0))
  _JOB_DONE["${jid}"]=1
  _iht_record_time "${label}" "${elapsed}" "ok"
  echo "[postprocess] ${label} job ${jid} COMPLETED ($(_iht_fmt_elapsed "${elapsed}"))"
  return 0
}

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

_script_for_step() {
  case "$1" in
    roms2d) echo "${_POST_ROOT}/post_roms2d/slurm_run_post_roms2d.bash" ;;
    roms3d) echo "${_POST_ROOT}/post_roms3d/slurm_run_post_roms3d.bash" ;;
    wrf2d)  echo "${_POST_ROOT}/post_wrf2d/slurm_run_post_wrf2d.bash" ;;
    wrf3d)  echo "${_POST_ROOT}/post_wrf3d/slurm_run_post_wrf3d.bash" ;;
    *) return 1 ;;
  esac
}

# Concurrent array tasks (match legacy %9)
_ARRAY_CONCUR=9

for step in "${_STEPS[@]}"; do
  script="$(_script_for_step "${step}")"
  if [[ ! -f "${script}" ]]; then
    echo "ERROR: missing script for ${step}: ${script}" >&2
    exit 1
  fi
  _sbatch_step "${step}" "${script}" --array="0-${_ARRAY_MAX}%${_ARRAY_CONCUR}"
done

_iht_print_timing_summary
echo "[postprocess] done ${START} → ${END} steps=${_STEPS[*]}"
