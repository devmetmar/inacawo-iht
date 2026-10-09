#!/bin/bash
# Portable bootstrap for InaCAWO hindcast scripts (interactive or SLURM).
# Usage:
#   source "${HOME}/inacawo-iht/setup_env.bash"
#   source setup_env.bash --cds-key 'UID:APIKEY' --cmems-user U --cmems-pass P
#
# Helpers live under src/ (setup_credentials.bash, setup_vault.bash, templates).
# Do not run those scripts alone — always enter via this file.

_IHT_SETUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Prefer the directory of this file; fall back to $HOME/inacawo-iht
if [[ -f "${_IHT_SETUP_DIR}/env" ]]; then
  export WORK_BASE="${WORK_BASE:-${_IHT_SETUP_DIR}}"
elif [[ -f "${HOME}/inacawo-iht/env" ]]; then
  export WORK_BASE="${HOME}/inacawo-iht"
else
  echo "ERROR: cannot find inacawo-iht/env (looked in ${_IHT_SETUP_DIR} and \$HOME/inacawo-iht)" >&2
  return 1 2>/dev/null || exit 1
fi

export IHT_SRC_DIR="${WORK_BASE}/src"

_iht_setup_usage() {
  cat <<'EOF' >&2
Usage: source setup_env.bash [options]

Optional credentials (writes ~/.cdsapirc and CMEMS credential file):
  --cds-key UID:APIKEY     CDS / cdsapi personal key
  --cds-url URL            CDS API url (default: https://cds.climate.copernicus.eu/api)
  --cmems-user USER        Copernicus Marine username
  --cmems-pass PASS        Copernicus Marine password
  -h, --help               Show this help (does not load the env)

Also: IHT_VAULT_CREDS=1 for operator Vault pull (see src/setup_vault.bash).
Manual / dummy bootstrap: src/credentials/README.md
EOF
}

# Parse args inside a function so `shift` does not alter the caller's "$@".
_IHT_CDS_KEY=""
_IHT_CDS_URL="https://cds.climate.copernicus.eu/api"
_IHT_CMEMS_USER=""
_IHT_CMEMS_PASS=""
_IHT_SETUP_HELP=0
_iht_parse_setup_env_args() {
  _IHT_CDS_KEY=""
  _IHT_CDS_URL="https://cds.climate.copernicus.eu/api"
  _IHT_CMEMS_USER=""
  _IHT_CMEMS_PASS=""
  _IHT_SETUP_HELP=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --cds-key) _IHT_CDS_KEY="${2:-}"; shift 2 ;;
      --cds-url) _IHT_CDS_URL="${2:-}"; shift 2 ;;
      --cmems-user) _IHT_CMEMS_USER="${2:-}"; shift 2 ;;
      --cmems-pass|--cmems-password) _IHT_CMEMS_PASS="${2:-}"; shift 2 ;;
      -h|--help) _IHT_SETUP_HELP=1; shift ;;
      *)
        echo "ERROR: unknown setup_env argument: $1" >&2
        _iht_setup_usage
        return 2
        ;;
    esac
  done
  return 0
}
_iht_parse_setup_env_args "$@" || return $?

if [[ "${_IHT_SETUP_HELP}" -eq 1 ]]; then
  _iht_setup_usage
  return 0 2>/dev/null || exit 0
fi

# shellcheck disable=SC1091
source "${WORK_BASE}/env"

# API credentials helpers (src/) — not standalone entrypoints.
# shellcheck disable=SC1091
if [[ -f "${IHT_SRC_DIR}/setup_vault.bash" ]]; then
  source "${IHT_SRC_DIR}/setup_vault.bash" || {
    echo "ERROR: Vault credential setup failed" >&2
    return 1 2>/dev/null || exit 1
  }
fi
# shellcheck disable=SC1091
if [[ -f "${IHT_SRC_DIR}/setup_credentials.bash" ]]; then
  source "${IHT_SRC_DIR}/setup_credentials.bash"
fi

# Optional CLI → write credential files, then seed dummies only for gaps
if declare -F iht_write_credentials_from_cli >/dev/null 2>&1; then
  iht_write_credentials_from_cli \
    "${_IHT_CDS_URL}" "${_IHT_CDS_KEY}" \
    "${_IHT_CMEMS_USER}" "${_IHT_CMEMS_PASS}" || {
      echo "ERROR: failed to write credentials from setup_env arguments" >&2
      return 1 2>/dev/null || exit 1
    }
fi
if declare -F iht_ensure_dummy_credentials >/dev/null 2>&1; then
  iht_ensure_dummy_credentials
fi

if [[ -z "${CONDA_BASE:-}" || ! -f "${CONDA_BASE}/etc/profile.d/conda.sh" ]]; then
  echo "ERROR: CONDA_BASE is unset or invalid: '${CONDA_BASE:-}'" >&2
  return 1 2>/dev/null || exit 1
fi

# shellcheck disable=SC1091
source "${CONDA_BASE}/etc/profile.d/conda.sh"
# Prefer envs under this Miniforge (set in inacawo-deps/env); activate by prefix
# Offline users typically point at HINDCAST_SHARED_ENV on scratch (no private copy).
export CONDA_ENVS_DIRS="${CONDA_ENVS_DIRS:-${CONDA_BASE}/envs}"
_HINDCAST_PREFIX="${HINDCAST_ENV_PREFIX:-${CONDA_ENVS_DIRS}/${HINDCAST_ENV_NAME:-hindcast}}"
if [[ -d "${_HINDCAST_PREFIX}/conda-meta" ]]; then
  conda activate "${_HINDCAST_PREFIX}"
else
  echo "ERROR: hindcast env not found at ${_HINDCAST_PREFIX}" >&2
  echo "       Online:  bash \$HOME/inacawo-deps/install_hindcast_env.bash" >&2
  echo "       Offline: bash \$HOME/inacawo-deps/install_hindcast_env.bash --offline" >&2
  echo "                (uses shared env at \$HINDCAST_SHARED_ENV)" >&2
  return 1 2>/dev/null || exit 1
fi
# Ensure this user's LO tree wins for editable lo_tools (shared env is read-only)
if [[ -n "${LO:-}" && -d "${LO}/lo_tools/lo_tools" ]]; then
  export LO_TOOLS_PKG="${LO}/lo_tools/lo_tools"
fi

# Default: compact path summary. Full list: IHT_SHOW_PATHS=1. Silence: IHT_QUIET=1.
export VAULT_TOKEN_FILE="${VAULT_TOKEN_FILE:-${IHT_SRC_DIR}/credentials/vault-token}"
export CDSAPI_RC="${CDSAPI_RC:-${HOME}/.cdsapirc}"
export VAULT_ADDR="${VAULT_ADDR:-http://202.90.199.148:8200}"

_iht_print_env_paths() {
  [[ "${IHT_QUIET:-0}" == "1" ]] && return 0
  local var val
  _iht_path_line() {
    var="$1"
    val="${!var-}"
    printf '  %-22s %s\n' "${var}" "${val:-(unset)}"
  }
  _iht_path_group() {
    local title="$1"; shift
    echo "  # ${title}"
    for var in "$@"; do
      _iht_path_line "${var}"
    done
  }

  echo "[iht] env ready (hindcast)"
  if [[ "${IHT_SHOW_PATHS:-0}" == "1" ]]; then
    _iht_path_group "roots" \
      WORK_BASE DEPS_BASE MODEL_BASE SCRATCH CONDA_BASE HINDCAST_ENV_PREFIX \
      HINDCAST_SHARED_ENV LIBDEP COAWST_ENV IHT_SRC_DIR
    _iht_path_group "LiveOcean" \
      LO LO_TOOLS_PKG LO_USER LO_DATA LO_OUTPUT LO_ROMS
    _iht_path_group "CAWO scratch" \
      CAWO_HINDCAST_BASE CAWO_INPUT CAWO_HINDCAST_RUN CAWO_OUTPUT CAWO_POST
    _iht_path_group "preprocess" \
      ERA5_BASE_DIR GLORYS_BASE_DIR WPS_RUN_DIR ROMS_FORCING
    _iht_path_group "shared inputs" \
      SHARED_DATA WPS_STATIC_DIR WRF_DIR WRF_STATIC_DIR WRF_STATIC_EXTRA_DIR \
      GEOGRID_FILE GRID_DATA SWAN_STATIC VARINFO GRID_SCRIP IN_TEMPLATES
    _iht_path_group "vault / credentials" \
      VAULT_ADDR VAULT_TOKEN_FILE CDSAPI_RC IHT_LOG_DIR
  else
    # Compact default (main workflow paths only)
    _iht_path_group "repos" WORK_BASE DEPS_BASE MODEL_BASE IHT_LOG_DIR
    _iht_path_group "scratch" CAWO_INPUT CAWO_HINDCAST_RUN CAWO_OUTPUT CAWO_POST
    _iht_path_group "preprocess" ERA5_BASE_DIR GLORYS_BASE_DIR WPS_RUN_DIR ROMS_FORCING
    _iht_path_group "shared" SHARED_DATA GRID_DATA IN_TEMPLATES
    _iht_path_group "vault" VAULT_ADDR VAULT_TOKEN_FILE CDSAPI_RC
    echo "  # full list: IHT_SHOW_PATHS=1"
  fi
  unset -f _iht_path_line _iht_path_group
}

_iht_print_env_paths
unset -f _iht_print_env_paths

# Status at end: dummy vs real credentials
if declare -F iht_check_manual_credentials >/dev/null 2>&1; then
  iht_check_manual_credentials
fi
