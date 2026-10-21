#!/bin/bash
# Launch Jupyter Lab on a Slurm compute node + login localhost proxy.
#
# Usage:
#   ./start_jupyter_slurm.bash
#   ./start_jupyter_slurm.bash --partition DEV1 --cpus 8 --mem 64G --time 04:00:00
#
# After it prints "Jupyter ready":
#   Cursor (Remote-SSH on login) → Existing Jupyter Server → paste the
#   localhost URL (http://localhost:<port>/lab?token=...).
#
# Laptop Chrome cannot resolve mdcXXX. Either:
#   - Cursor Ports → Forward <port>, then open the localhost URL, or
#   - From your LAPTOP: ssh -N -L <port>:127.0.0.1:<port> USER@mdclogin1
#
set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_IHT_ROOT="$(cd "${_SCRIPT_DIR}/../.." && pwd)"
_PROXY_PY="${_SCRIPT_DIR}/jupyter_login_proxy.py"

PARTITION="${IHT_SLURM_PARTITION:-DEV1}"
CPUS=8
MEM=64G
TIME=04:00:00
# 0 = job picks a free ephemeral port (avoids stale :8888 conflicts)
PORT=0
NOTEBOOK_DIR="${_SCRIPT_DIR}"
LOGIN_HOST="${IHT_LOGIN_HOST:-mdclogin1}"
KEEP_OLD=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --partition) PARTITION="$2"; shift 2 ;;
    --cpus) CPUS="$2"; shift 2 ;;
    --mem) MEM="$2"; shift 2 ;;
    --time) TIME="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --dir) NOTEBOOK_DIR="$2"; shift 2 ;;
    --login-host) LOGIN_HOST="$2"; shift 2 ;;
    --keep-old) KEEP_OLD=1; shift ;;
    -h|--help)
      sed -n '2,15p' "$0" | sed '/^set /d'
      exit 0
      ;;
    *)
      echo "ERROR: unknown arg: $1" >&2
      exit 2
      ;;
  esac
done

# shellcheck disable=SC1091
source "${_IHT_ROOT}/setup_env.bash"

if ! python -c "import jupyterlab" >/dev/null 2>&1; then
  echo "ERROR: jupyterlab missing in hindcast env" >&2
  echo "       mamba install -n hindcast -c conda-forge jupyterlab notebook" >&2
  exit 1
fi
if [[ ! -f "${_PROXY_PY}" ]]; then
  echo "ERROR: missing ${_PROXY_PY}" >&2
  exit 1
fi

if [[ "${KEEP_OLD}" -eq 0 ]]; then
  old_jobs="$(squeue -h -u "${USER}" -n iht_jupyter -o '%i' 2>/dev/null || true)"
  if [[ -n "${old_jobs}" ]]; then
    echo "[jupyter] scancel previous iht_jupyter job(s): ${old_jobs//$'\n'/ }"
    # shellcheck disable=SC2086
    scancel ${old_jobs} || true
    sleep 2
  fi
fi

CONN_DIR="${IHT_LOG_DIR:-${_IHT_ROOT}/logs}/jupyter"
mkdir -p "${CONN_DIR}"
TS="$(date +%Y%m%d_%H%M%S)"
CONN_FILE="${CONN_DIR}/jupyter_${TS}.json"
LATEST_LINK="${CONN_DIR}/latest.json"
JOB_SCRIPT="${CONN_DIR}/jupyter_${TS}.sbatch"
LOG_OUT="${CONN_DIR}/jupyter_${TS}.out"
PROXY_PID_FILE="${CONN_DIR}/proxy.pid"
PROXY_LOG="${CONN_DIR}/proxy.log"

cat > "${JOB_SCRIPT}" <<EOF
#!/bin/bash
#SBATCH --job-name=iht_jupyter
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=${CPUS}
#SBATCH --mem=${MEM}
#SBATCH --time=${TIME}
#SBATCH --partition=${PARTITION}
#SBATCH --output=${LOG_OUT}
#SBATCH --error=${LOG_OUT}

set -euo pipefail
source "${_IHT_ROOT}/setup_env.bash"
cd "${NOTEBOOK_DIR}"

export IHT_JUP_CONN="${CONN_FILE}"
export IHT_JUP_LATEST="${LATEST_LINK}"
export IHT_JUP_DIR="${NOTEBOOK_DIR}"
export IHT_JUP_LOGIN="${LOGIN_HOST}"
export IHT_JUP_USER="${USER}"
export IHT_JUP_PREF_PORT="${PORT}"

HOST="\$(hostname -f)"
PORT="\$(python - <<'PY'
import os, socket
pref = int(os.environ["IHT_JUP_PREF_PORT"])
s = socket.socket()
try:
    s.bind(("", pref))
    print(s.getsockname()[1])
except OSError:
    s.bind(("", 0))
    print(s.getsockname()[1])
finally:
    s.close()
PY
)"
TOKEN="\$(python -c 'import secrets; print(secrets.token_hex(16))')"
export IHT_JUP_HOST="\${HOST}"
export IHT_JUP_PORT="\${PORT}"
export IHT_JUP_TOKEN="\${TOKEN}"

python - <<'PY'
import json, os
from pathlib import Path

host = os.environ["IHT_JUP_HOST"]
port = int(os.environ["IHT_JUP_PORT"])
token = os.environ["IHT_JUP_TOKEN"]
user = os.environ["IHT_JUP_USER"]
login = os.environ["IHT_JUP_LOGIN"]
nbdir = os.environ["IHT_JUP_DIR"]
conn = Path(os.environ["IHT_JUP_CONN"])
latest = Path(os.environ["IHT_JUP_LATEST"])

info = {
    "host": host,
    "port": port,
    "token": token,
    "url": f"http://{host}:{port}/lab?token={token}",
    "localhost_url": f"http://localhost:{port}/lab?token={token}",
    "notebook_dir": nbdir,
    "slurm_job_id": os.environ.get("SLURM_JOB_ID", ""),
    "tunnel": f"ssh -N -L {port}:{host}:{port} {user}@{login}",
}
conn.write_text(json.dumps(info, indent=2) + "\n")
if latest.exists() or latest.is_symlink():
    latest.unlink()
latest.symlink_to(conn.name)
print("wrote", conn)
print("url", info["url"])
print("localhost_url", info["localhost_url"])
PY

echo "[jupyter] starting on \${HOST}:\${PORT}"
exec jupyter lab \\
  --no-browser \\
  --ip=0.0.0.0 \\
  --port="\${PORT}" \\
  --ServerApp.token="\${TOKEN}" \\
  --ServerApp.password="" \\
  --ServerApp.root_dir="${NOTEBOOK_DIR}" \\
  --ServerApp.allow_origin="*" \\
  --ServerApp.allow_remote_access=True
EOF

chmod +x "${JOB_SCRIPT}"
JOB_ID="$(sbatch --parsable "${JOB_SCRIPT}")"
echo "submitted job ${JOB_ID}"
echo "log: ${LOG_OUT}"
echo "waiting for connection file: ${CONN_FILE}"

for _ in $(seq 1 90); do
  if [[ -f "${CONN_FILE}" ]]; then
    echo
    echo "=== connection file written (waiting for Jupyter listen) ==="
    python -c "import json; print(json.dumps(json.load(open('${CONN_FILE}')), indent=2))"

    # Conn JSON is written BEFORE jupyter lab binds. Wait for compute:port first,
    # otherwise the login proxy hits ConnectionRefused and used to crash.
    echo "[jupyter] waiting for compute Jupyter TCP ..."
    if ! python - "${CONN_FILE}" "${JOB_ID}" <<'WAIT_COMPUTE'
import json, socket, sys, time, subprocess

d = json.load(open(sys.argv[1]))
job_id = sys.argv[2]
host, port = d["host"], int(d["port"])
ok = False
for _ in range(120):  # ~60s
    # bail if Slurm job vanished
    try:
        out = subprocess.check_output(
            ["squeue", "-h", "-j", job_id, "-o", "%T"],
            text=True,
            stderr=subprocess.DEVNULL,
        ).strip()
    except Exception:
        out = ""
    if not out:
        raise SystemExit(f"job {job_id} ended before Jupyter listened on {host}:{port}")
    s = socket.socket()
    s.settimeout(1)
    try:
        s.connect((host, port))
        ok = True
        break
    except OSError:
        time.sleep(0.5)
    finally:
        s.close()
if not ok:
    raise SystemExit(f"timed out waiting for {host}:{port}")
print(f"compute_ok {host}:{port}")
WAIT_COMPUTE
    then
      echo "ERROR: Jupyter never listened on compute; see ${LOG_OUT}" >&2
      tail -n 100 "${LOG_OUT}" 2>/dev/null || true
      exit 1
    fi

    # Stop previous login proxy (if any)
    if [[ -f "${PROXY_PID_FILE}" ]]; then
      old_pid="$(tr -d '[:space:]' < "${PROXY_PID_FILE}" || true)"
      if [[ -n "${old_pid}" ]]; then
        kill "${old_pid}" 2>/dev/null || true
      fi
      rm -f "${PROXY_PID_FILE}"
    fi

    echo "[jupyter] starting login proxy 127.0.0.1:<port> → compute ..."
    nohup python "${_PROXY_PY}" \
      --conn "${CONN_FILE}" \
      --pid-file "${PROXY_PID_FILE}" \
      >"${PROXY_LOG}" 2>&1 &
    disown || true

    # Wait until localhost accepts the token (same path Cursor will use)
    if ! python - "${CONN_FILE}" <<'WAIT'
import json, sys, time, urllib.request

d = json.load(open(sys.argv[1]))
url = f"http://127.0.0.1:{d['port']}/api/sessions?token={d['token']}"
ok = False
for _ in range(80):  # ~20s
    try:
        with urllib.request.urlopen(url, timeout=2) as r:
            if r.status == 200:
                ok = True
                break
    except Exception:
        time.sleep(0.25)
if not ok:
    raise SystemExit("login proxy did not become ready")
print("proxy_ok")
WAIT
    then
      echo "ERROR: login proxy failed; see ${PROXY_LOG}" >&2
      tail -n 40 "${PROXY_LOG}" 2>/dev/null || true
      exit 1
    fi

    echo
    echo "=== Jupyter ready on compute ==="
    python -c "import json; print(json.dumps(json.load(open('${CONN_FILE}')), indent=2))"

    # Enrich connection JSON for the user
    python - "${CONN_FILE}" "${LOGIN_HOST}" "${USER}" <<'ENRICH'
import json, sys
from pathlib import Path

conn = Path(sys.argv[1])
login = sys.argv[2]
user = sys.argv[3]
d = json.load(open(conn))
port = int(d["port"])
token = d["token"]
d["browser_url"] = f"http://localhost:{port}/lab?token={token}"
d["tunnel_from_laptop"] = f"ssh -N -L {port}:127.0.0.1:{port} {user}@{login}"
d["proxy_ok"] = True
conn.write_text(json.dumps(d, indent=2) + "\n")
# keep latest in sync
latest = conn.parent / "latest.json"
if latest.exists() or latest.is_symlink():
    latest.unlink()
latest.symlink_to(conn.name)
ENRICH

    echo
    echo "=== Use this in Cursor (Remote-SSH) ==="
    echo "Existing Jupyter Server → paste:"
    python -c "import json; print('  ', json.load(open('${CONN_FILE}'))['browser_url'])"
    echo
    echo "If Chrome on the laptop still fails: Ports → Forward Port" \
      "$(python -c "import json; print(json.load(open('${CONN_FILE}'))['port'])")" \
      "then reopen the same localhost URL."
    echo
    echo "Laptop terminal tunnel (optional):"
    python -c "import json; print('  ', json.load(open('${CONN_FILE}'))['tunnel_from_laptop'])"
    echo
    echo "Stop later: scancel ${JOB_ID}"
    echo "           kill \$(cat ${PROXY_PID_FILE})   # login proxy"
    exit 0
  fi
  state="$(squeue -h -j "${JOB_ID}" -o '%T' 2>/dev/null | head -n1 || true)"
  if [[ -z "${state}" ]]; then
    echo "ERROR: job ${JOB_ID} ended before connection file appeared; see ${LOG_OUT}" >&2
    tail -n 100 "${LOG_OUT}" 2>/dev/null || true
    exit 1
  fi
  sleep 2
done

echo "ERROR: timed out waiting for ${CONN_FILE}; job=${JOB_ID}" >&2
tail -n 100 "${LOG_OUT}" 2>/dev/null || true
exit 1
