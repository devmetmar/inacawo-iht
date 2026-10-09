#!/bin/bash
# Per-user API credentials bootstrap + check (called at end of setup_env.bash).
# - If missing: seed dummy files under $HOME for participants to edit later
# - If present: detect placeholder vs real (not just file existence)
# Quiet when IHT_QUIET=1. Skip seeding with IHT_SKIP_CRED_BOOTSTRAP=1.
# Does not print secret values.

_iht_creds_warn() { echo "WARNING: [credentials] $*" >&2; }
_iht_creds_info() { echo "INFO: [credentials] $*" >&2; }

# True if file/text still looks like a training placeholder.
_iht_creds_is_dummy_text() {
  local text="$1"
  echo "${text}" | grep -Eiq \
    'IHT_DUMMY_CREDENTIAL|dummy-training|dummy_cmems_|_replace_me|REPLACE_ME|<UID>|<API-KEY>|00000000-0000-0000-0000-000000000000'
}

_iht_creds_cds_status() {
  # prints: missing | dummy | ok
  local rc="${CDSAPI_RC:-${HOME}/.cdsapirc}"
  if [[ ! -f "${rc}" ]]; then
    echo missing
    return
  fi
  if _iht_creds_is_dummy_text "$(cat "${rc}" 2>/dev/null || true)"; then
    echo dummy
    return
  fi
  # Require a non-empty key: line
  if ! grep -Eq '^[[:space:]]*key:[[:space:]]*[^[:space:]].+' "${rc}" 2>/dev/null; then
    echo dummy
    return
  fi
  echo ok
}

_iht_creds_cmems_status() {
  # prints: missing | dummy | ok
  local cmems_file="${HOME}/.copernicusmarine/.copernicusmarine-credentials"
  local user="${COPERNICUSMARINE_SERVICE_USERNAME:-}"
  local pass="${COPERNICUSMARINE_SERVICE_PASSWORD:-}"

  if [[ -n "${user}" || -n "${pass}" ]]; then
    if _iht_creds_is_dummy_text "${user}${pass}"; then
      echo dummy
    else
      echo ok
    fi
    return
  fi

  if [[ ! -f "${cmems_file}" ]]; then
    echo missing
    return
  fi
  if _iht_creds_is_dummy_text "$(cat "${cmems_file}" 2>/dev/null || true)"; then
    echo dummy
    return
  fi
  # Minimal JSON shape with non-empty username/password
  if command -v python3 >/dev/null 2>&1 || command -v python >/dev/null 2>&1; then
    local py=python3
    command -v python3 >/dev/null 2>&1 || py=python
    if "${py}" -c '
import json,sys
p=sys.argv[1]
try:
    o=json.load(open(p))
except Exception:
    sys.exit(2)
u=str(o.get("username") or o.get("user") or "").strip()
pw=str(o.get("password") or o.get("pass") or "").strip()
sys.exit(0 if u and pw else 1)
' "${cmems_file}" 2>/dev/null; then
      echo ok
    else
      echo dummy
    fi
    return
  fi
  echo ok
}

# Seed dummy credential files once (never overwrite existing).
iht_ensure_dummy_credentials() {
  if [[ "${IHT_SKIP_CRED_BOOTSTRAP:-0}" == "1" ]]; then
    return 0
  fi

  local rc="${CDSAPI_RC:-${HOME}/.cdsapirc}"
  local cmems_dir="${HOME}/.copernicusmarine"
  local cmems_file="${cmems_dir}/.copernicusmarine-credentials"
  local tmpl_root="${IHT_SRC_DIR:-${WORK_BASE}/src}/credentials"
  local tmpl_cds="${tmpl_root}/cdsapirc.dummy"
  local tmpl_cmems="${tmpl_root}/cmems-credentials.dummy.json"
  local seeded=0

  if [[ ! -f "${rc}" ]]; then
    if [[ -f "${tmpl_cds}" ]]; then
      umask 077
      cp "${tmpl_cds}" "${rc}"
      chmod 600 "${rc}"
    else
      umask 077
      printf '%s\n' \
        '# IHT_DUMMY_CREDENTIAL — replace with personal CDS key' \
        'url: https://cds.climate.copernicus.eu/api' \
        'key: 00000000-0000-0000-0000-000000000000:dummy-training-key-replace-me' \
        > "${rc}"
      chmod 600 "${rc}"
    fi
    seeded=1
    [[ "${IHT_QUIET:-0}" != "1" ]] && \
      _iht_creds_info "seeded dummy cdsapi config → ${rc} (edit with your CDS key)"
  fi

  if [[ ! -f "${cmems_file}" && -z "${COPERNICUSMARINE_SERVICE_USERNAME:-}" ]]; then
    mkdir -p "${cmems_dir}"
    chmod 700 "${cmems_dir}"
    umask 077
    if [[ -f "${tmpl_cmems}" ]]; then
      cp "${tmpl_cmems}" "${cmems_file}"
    else
      printf '%s\n' \
        '{' \
        '  "username": "dummy_cmems_user",' \
        '  "password": "dummy_cmems_password_replace_me",' \
        '  "_comment": "IHT_DUMMY_CREDENTIAL — replace via: copernicusmarine login"' \
        '}' \
        > "${cmems_file}"
    fi
    chmod 600 "${cmems_file}"
    seeded=1
    [[ "${IHT_QUIET:-0}" != "1" ]] && \
      _iht_creds_info "seeded dummy CMEMS credentials → ${cmems_file} (run: copernicusmarine login)"
  fi

  return 0
}

iht_check_manual_credentials() {
  # Always seed missing files first (even under IHT_QUIET for SLURM/login consistency)
  iht_ensure_dummy_credentials

  if [[ "${IHT_QUIET:-0}" == "1" ]]; then
    return 0
  fi

  local rc="${CDSAPI_RC:-${HOME}/.cdsapirc}"
  local cds_st cmems_st
  cds_st="$(_iht_creds_cds_status)"
  cmems_st="$(_iht_creds_cmems_status)"

  case "${cds_st}" in
    ok) ;;
    dummy)
      _iht_creds_warn "CDS/cdsapi still DUMMY placeholder — update ${rc}"
      _iht_creds_warn "  get key: https://cds.climate.copernicus.eu/  then edit url/key"
      ;;
    missing)
      _iht_creds_warn "CDS/cdsapi missing — ${rc}"
      ;;
  esac

  case "${cmems_st}" in
    ok) ;;
    dummy)
      _iht_creds_warn "CMEMS/copernicusmarine still DUMMY placeholder"
      _iht_creds_warn "  replace with: copernicusmarine login"
      ;;
    missing)
      _iht_creds_warn "CMEMS/copernicusmarine not configured"
      _iht_creds_warn "  copernicusmarine login"
      ;;
  esac

  if [[ "${cds_st}" == "ok" && "${cmems_st}" == "ok" ]]; then
    _iht_creds_info "env + credentials ready (cdsapi: ${rc}; CMEMS: configured)"
    _iht_creds_info "hindcast env active — OK to run preprocess / download"
  else
    _iht_creds_warn "downloads will fail until placeholders are replaced — see \$WORK_BASE/src/credentials/README.md"
    [[ "${cds_st}" == "ok" ]] && _iht_creds_info "cdsapi OK (${rc})"
    [[ "${cmems_st}" == "ok" ]] && _iht_creds_info "CMEMS OK"
  fi
  return 0
}

# Write credential files from setup_env.bash CLI args (overwrites).
# Usage: iht_write_credentials_from_cli CDS_URL CDS_KEY CMEMS_USER CMEMS_PASS
# Empty args are skipped (partial update allowed).
iht_write_credentials_from_cli() {
  local cds_url="${1:-}"
  local cds_key="${2:-}"
  local cmems_user="${3:-}"
  local cmems_pass="${4:-}"
  local rc cmems_dir cmems_file py
  local wrote=0

  if [[ -n "${cds_key}" ]]; then
    rc="${CDSAPI_RC:-${HOME}/.cdsapirc}"
    [[ -z "${cds_url}" ]] && cds_url="https://cds.climate.copernicus.eu/api"
    umask 077
    printf 'url: %s\nkey: %s\n' "${cds_url}" "${cds_key}" > "${rc}"
    chmod 600 "${rc}"
    wrote=1
    [[ "${IHT_QUIET:-0}" != "1" ]] && \
      _iht_creds_info "wrote cdsapi config from setup_env args → ${rc}"
  fi

  if [[ -n "${cmems_user}" || -n "${cmems_pass}" ]]; then
    if [[ -z "${cmems_user}" || -z "${cmems_pass}" ]]; then
      _iht_creds_warn "need both --cmems-user and --cmems-pass"
      return 1
    fi
    cmems_dir="${HOME}/.copernicusmarine"
    cmems_file="${cmems_dir}/.copernicusmarine-credentials"
    mkdir -p "${cmems_dir}"
    chmod 700 "${cmems_dir}"
    umask 077
    py=python3
    command -v python3 >/dev/null 2>&1 || py=python
    "${py}" -c '
import json, sys
json.dump({"username": sys.argv[1], "password": sys.argv[2]}, open(sys.argv[3], "w"), indent=2)
open(sys.argv[3], "a").write("\n")
' "${cmems_user}" "${cmems_pass}" "${cmems_file}"
    chmod 600 "${cmems_file}"
    export COPERNICUSMARINE_SERVICE_USERNAME="${cmems_user}"
    export COPERNICUSMARINE_SERVICE_PASSWORD="${cmems_pass}"
    wrote=1
    [[ "${IHT_QUIET:-0}" != "1" ]] && \
      _iht_creds_info "wrote CMEMS credentials from setup_env args → ${cmems_file}"
  fi

  return 0
}

# Do not auto-seed on source — setup_env.bash calls iht_write_credentials_from_cli
# first (CLI args), then iht_ensure_dummy_credentials / iht_check_manual_credentials.
