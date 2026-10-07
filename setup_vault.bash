#!/bin/bash
# Fetch API credentials from HashiCorp Vault (KV v2) into local files / env.
# Sourced from setup_env.bash — do not execute directly.
#
# Required (one of):
#   export VAULT_TOKEN='hvs....'
#   or put the token in $VAULT_TOKEN_FILE
#     default: $WORK_BASE/vault-token  (copy from vault-token.example)
#
# Optional overrides:
#   VAULT_ADDR          default http://202.90.199.148:8200
#   VAULT_TOKEN_FILE    default ${WORK_BASE}/vault-token
#   IHT_VAULT_MOUNT     default secret
#   IHT_VAULT_PREFIX    default iht-hindcast
#   IHT_VAULT_SKIP=1    skip Vault entirely
#   IHT_VAULT_REQUIRED=1  treat Vault failures as fatal
#   IHT_VAULT_WRITE_CMEMS_FILE=1
#                       also write ~/.copernicusmarine/.copernicusmarine-credentials
#                       (OFF by default — prefer env-only so secrets are not on disk)
#   CDSAPI_RC           default ~/.cdsapirc  (cdsapi requires a file; mode 600)
#
# Expected KV paths (mount/data/prefix/<name>):
#   cdsapi              fields: url, key  -> writes $CDSAPI_RC
#   cmems | copernicusmarine
#                       fields: username|user, password|passwd|pass
#                       -> COPERNICUSMARINE_SERVICE_USERNAME / _PASSWORD (env only)

_iht_vault_warn() { echo "WARNING: [vault] $*" >&2; }
_iht_vault_err()  { echo "ERROR: [vault] $*" >&2; }

_iht_vault_fail() {
  if [[ "${IHT_VAULT_REQUIRED:-0}" == "1" ]]; then
    _iht_vault_err "$@"
    return 1
  fi
  [[ "${IHT_VAULT_VERBOSE:-0}" == "1" ]] && _iht_vault_warn "$@"
  return 0
}

_iht_vault_resolve_token() {
  if [[ -n "${VAULT_TOKEN:-}" ]]; then
    return 0
  fi
  local token_file="${VAULT_TOKEN_FILE:-${WORK_BASE}/vault-token}"
  if [[ -f "${token_file}" ]]; then
    # First non-empty, non-comment line; strip CR
    VAULT_TOKEN="$(
      sed -e 's/\r$//' -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d' "${token_file}" | head -n 1
    )"
    export VAULT_TOKEN
  fi
  if [[ -z "${VAULT_TOKEN:-}" ]]; then
    return 1
  fi
  return 0
}

# GET KV v2 secret; prints data.data JSON object to stdout. Returns non-zero on failure.
_iht_vault_get_json() {
  local name="$1"
  local addr="${VAULT_ADDR:-http://202.90.199.148:8200}"
  local mount="${IHT_VAULT_MOUNT:-secret}"
  local prefix="${IHT_VAULT_PREFIX:-iht-hindcast}"
  local url="${addr%/}/v1/${mount}/data/${prefix}/${name}"
  local resp http_code

  if ! command -v curl >/dev/null 2>&1; then
    _iht_vault_err "curl not found"
    return 1
  fi

  resp="$(curl -sS --max-time "${IHT_VAULT_TIMEOUT:-15}" \
    -w '\n%{http_code}' \
    --header "X-Vault-Token: ${VAULT_TOKEN}" \
    --request GET \
    "${url}" 2>&1)" || {
      _iht_vault_err "curl failed for ${name}: ${resp}"
      return 1
    }

  http_code="${resp##*$'\n'}"
  resp="${resp%$'\n'*}"

  if [[ "${http_code}" != "200" ]]; then
    _iht_vault_err "HTTP ${http_code} fetching ${prefix}/${name} (${url})"
    return 1
  fi

  # Prefer python (hindcast env / system); fall back to jq
  if command -v python3 >/dev/null 2>&1 || command -v python >/dev/null 2>&1; then
    local py=python3
    command -v python3 >/dev/null 2>&1 || py=python
    "${py}" -c '
import json, sys
j = json.load(sys.stdin)
if j.get("errors"):
    sys.stderr.write("vault errors: %s\n" % (j["errors"],))
    sys.exit(1)
data = (j.get("data") or {}).get("data")
if not isinstance(data, dict) or not data:
    sys.stderr.write("vault: empty data.data for secret\n")
    sys.exit(1)
json.dump(data, sys.stdout)
' <<<"${resp}" || return 1
  elif command -v jq >/dev/null 2>&1; then
    if echo "${resp}" | jq -e '.errors != null and (.errors | length) > 0' >/dev/null 2>&1; then
      _iht_vault_err "vault errors: $(echo "${resp}" | jq -c '.errors')"
      return 1
    fi
    echo "${resp}" | jq -c '.data.data' || return 1
  else
    _iht_vault_err "need python3 or jq to parse Vault JSON"
    return 1
  fi
}

_iht_vault_json_field() {
  # usage: _iht_vault_json_field '{"a":1}' a [alt...]
  local json="$1"; shift
  local py=python3
  command -v python3 >/dev/null 2>&1 || py=python
  "${py}" -c '
import json, sys
obj = json.loads(sys.argv[1])
for k in sys.argv[2:]:
    v = obj.get(k)
    if v is not None and str(v) != "":
        print(v, end="")
        sys.exit(0)
sys.exit(1)
' "${json}" "$@"
}

_iht_vault_apply_cdsapi() {
  local json url key rc tmp
  json="$(_iht_vault_get_json cdsapi)" || return 1
  url="$(_iht_vault_json_field "${json}" url URL)" || {
    _iht_vault_err "cdsapi secret missing field 'url'"
    return 1
  }
  key="$(_iht_vault_json_field "${json}" key KEY api_key)" || {
    _iht_vault_err "cdsapi secret missing field 'key'"
    return 1
  }
  rc="${CDSAPI_RC:-${HOME}/.cdsapirc}"
  tmp="$(mktemp "${TMPDIR:-/tmp}/cdsapirc.XXXXXX")"
  umask 077
  printf 'url: %s\nkey: %s\n' "${url}" "${key}" > "${tmp}"
  mv -f "${tmp}" "${rc}"
  chmod 600 "${rc}"
  [[ "${IHT_VAULT_VERBOSE:-0}" == "1" || "${IHT_SHOW_PATHS:-0}" == "1" ]] && \
    echo "[vault] wrote ${rc}"
}

_iht_vault_apply_copernicusmarine() {
  local json user pass cred_dir cred_file tmp name
  # Prefer site path `cmems`; keep `copernicusmarine` as alias.
  json=""
  for name in cmems copernicusmarine; do
    if json="$(_iht_vault_get_json "${name}" 2>/dev/null)"; then
      break
    fi
    json=""
  done
  [[ -n "${json}" ]] || return 1
  user="$(_iht_vault_json_field "${json}" username user USER USERNAME)" || {
    _iht_vault_err "cmems/copernicusmarine secret missing username/user"
    return 1
  }
  pass="$(_iht_vault_json_field "${json}" password passwd pass PASSWORD)" || {
    _iht_vault_err "cmems/copernicusmarine secret missing password/pass"
    return 1
  }
  # Env-only by default (not written to disk). copernicusmarine honors these.
  export COPERNICUSMARINE_SERVICE_USERNAME="${user}"
  export COPERNICUSMARINE_SERVICE_PASSWORD="${pass}"

  if [[ "${IHT_VAULT_WRITE_CMEMS_FILE:-0}" == "1" ]]; then
    # Opt-in only: persists secrets under $HOME (mode 600). Prefer env-only.
    cred_dir="${HOME}/.copernicusmarine"
    cred_file="${cred_dir}/.copernicusmarine-credentials"
    mkdir -p "${cred_dir}"
    chmod 700 "${cred_dir}"
    tmp="$(mktemp "${TMPDIR:-/tmp}/cmems.XXXXXX")"
    umask 077
    local py=python3
    command -v python3 >/dev/null 2>&1 || py=python
    "${py}" -c '
import json, sys
json.dump({
    "username": sys.argv[1],
    "password": sys.argv[2],
}, open(sys.argv[3], "w"), indent=2)
' "${user}" "${pass}" "${tmp}"
    mv -f "${tmp}" "${cred_file}"
    chmod 600 "${cred_file}"
    [[ "${IHT_VAULT_VERBOSE:-0}" == "1" || "${IHT_SHOW_PATHS:-0}" == "1" ]] && \
      echo "[vault] wrote ${cred_file} (IHT_VAULT_WRITE_CMEMS_FILE=1)"
  else
    [[ "${IHT_VAULT_VERBOSE:-0}" == "1" || "${IHT_SHOW_PATHS:-0}" == "1" ]] && \
      echo "[vault] CMEMS via env COPERNICUSMARINE_SERVICE_* (no credential file)"
  fi
}

iht_vault_setup_credentials() {
  if [[ "${IHT_VAULT_SKIP:-0}" == "1" ]]; then
    return 0
  fi

  if ! _iht_vault_resolve_token; then
    if [[ "${IHT_VAULT_REQUIRED:-0}" == "1" ]]; then
      _iht_vault_err "VAULT_TOKEN unset and no token file at \${VAULT_TOKEN_FILE:-\$WORK_BASE/vault-token}"
      _iht_vault_err "copy vault-token.example → vault-token and paste a real token"
      return 1
    fi
    # Quiet skip when Vault is optional (compute nodes / offline).
    return 0
  fi

  export VAULT_ADDR="${VAULT_ADDR:-http://202.90.199.148:8200}"

  local ok=0
  if _iht_vault_apply_cdsapi; then
    ok=1
  else
    _iht_vault_fail "could not apply cdsapi credentials from Vault"
    [[ "${IHT_VAULT_REQUIRED:-0}" == "1" ]] && return 1
  fi

  if _iht_vault_apply_copernicusmarine 2>/dev/null; then
    ok=1
  else
    _iht_vault_fail "could not apply cmems/copernicusmarine credentials from Vault"
    [[ "${IHT_VAULT_REQUIRED:-0}" == "1" ]] && return 1
  fi

  if [[ "${ok}" -eq 0 && "${IHT_VAULT_REQUIRED:-0}" == "1" ]]; then
    return 1
  fi
  return 0
}

iht_vault_setup_credentials || return $?
