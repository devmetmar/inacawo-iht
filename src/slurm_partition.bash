# Shared Slurm partition picker for InaCAWO iht.
# Prefer HDCAST when the user's Slurm account is allowed; else DEV1
# (avoids stuck PENDING (PartitionConfig)).
#
# Usage (after USER is set):
#   PARTITION_ARG=""   # optional CLI override from entrypoint
#   # shellcheck source=src/slurm_partition.bash
#   source "${WORK_BASE}/src/slurm_partition.bash"
#   _iht_resolve_slurm_partition
#
# Sets: IHT_SLURM_PARTITION, SBATCH_PARTITION, _PARTITION_SOURCE
#   (cli | env | auto)
#
# Override without CLI: IHT_SLURM_PARTITION=NAME
# Preferred / fallback: IHT_SLURM_PARTITION_PREFERRED / IHT_SLURM_PARTITION_FALLBACK

_iht_user_slurm_accounts() {
  if command -v sacctmgr >/dev/null 2>&1; then
    sacctmgr -n show associations where user="${USER}" format=Account -P 2>/dev/null \
      | awk -F'|' 'NF && $1 != "" {print $1}' | sort -u
  fi
}

_iht_partition_allow_accounts() {
  local part="$1"
  local line
  line="$(scontrol show partition "${part}" -o 2>/dev/null || true)"
  [[ -n "${line}" ]] || return 1
  if [[ "${line}" =~ AllowAccounts=([^ ]+) ]]; then
    echo "${BASH_REMATCH[1]}"
    return 0
  fi
  echo "ALL"
}

_iht_account_allowed_on_partition() {
  local part="$1"
  local allow a uacc
  allow="$(_iht_partition_allow_accounts "${part}" || true)"
  [[ -n "${allow}" ]] || return 1
  [[ "${allow}" == "ALL" ]] && return 0
  while IFS= read -r uacc; do
    [[ -z "${uacc}" ]] && continue
    IFS=',' read -r -a _allowed <<< "${allow}"
    for a in "${_allowed[@]}"; do
      [[ "${uacc}" == "${a}" ]] && return 0
    done
  done < <(_iht_user_slurm_accounts)
  return 1
}

# Must not run in a subshell (exports + _PARTITION_SOURCE).
_iht_resolve_slurm_partition() {
  local preferred="${IHT_SLURM_PARTITION_PREFERRED:-HDCAST}"
  local fallback="${IHT_SLURM_PARTITION_FALLBACK:-DEV1}"
  if [[ -n "${PARTITION_ARG:-}" ]]; then
    _PARTITION_SOURCE="cli"
    IHT_SLURM_PARTITION="${PARTITION_ARG}"
  elif [[ -n "${IHT_SLURM_PARTITION:-}" ]]; then
    _PARTITION_SOURCE="env"
  else
    _PARTITION_SOURCE="auto"
    if command -v scontrol >/dev/null 2>&1 && _iht_account_allowed_on_partition "${preferred}"; then
      IHT_SLURM_PARTITION="${preferred}"
    else
      IHT_SLURM_PARTITION="${fallback}"
    fi
  fi
  export IHT_SLURM_PARTITION
  export SBATCH_PARTITION="${IHT_SLURM_PARTITION}"
}

_iht_log_slurm_partition() {
  local prefix="${1:-[slurm]}"
  local preferred="${IHT_SLURM_PARTITION_PREFERRED:-HDCAST}"
  local fallback="${IHT_SLURM_PARTITION_FALLBACK:-DEV1}"
  case "${_PARTITION_SOURCE:-auto}" in
    cli) echo "${prefix} partition=${IHT_SLURM_PARTITION} (--partition)" ;;
    env) echo "${prefix} partition=${IHT_SLURM_PARTITION} (IHT_SLURM_PARTITION)" ;;
    *)
      if [[ "${IHT_SLURM_PARTITION}" == "${fallback}" ]]; then
        echo "${prefix} partition=${IHT_SLURM_PARTITION} (auto: no Slurm account on ${preferred} → fallback)"
      else
        echo "${prefix} partition=${IHT_SLURM_PARTITION} (auto: account allowed on ${preferred})"
      fi
      ;;
  esac
}
