#!/bin/bash
# Portable bootstrap for InaCAWO hindcast scripts (interactive or SLURM).
# Usage from any script in this repo:
#   source "${HOME}/inacawo-iht/setup_env.bash"
# or, if WORK_BASE is already set:
#   source "${WORK_BASE}/setup_env.bash"
#
# Loads env vars, activates the unified `hindcast` conda env.

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

# shellcheck disable=SC1091
source "${WORK_BASE}/env"

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
