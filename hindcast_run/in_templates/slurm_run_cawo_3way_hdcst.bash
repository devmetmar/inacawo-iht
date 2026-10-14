#!/bin/bash
# Partition: submit_days.bash always passes --partition=${IHT_SLURM_PARTITION}
# (auto HDCAST→DEV1). Keep HDCAST here only as a manual-sbatch fallback for
# accounts that are allowed on HDCAST.
#SBATCH --partition=HDCAST
#SBATCH --job-name=HDCST-FT        #passed by script
#SBATCH --nodes=88                # production 88×96 (restgen DEV1-proven mlx/UCX recipe)
#SBATCH --ntasks-per-node=96
#SBATCH --exclusive
#SBATCH --time=02:00:00
#SBATCH --output=log_run_%j.out
#SBATCH --export=ALL
# Full node RAM (RealMemory≈251 GiB). --mem=230G OOMs: peak MaxRSS ~242 GiB → SIGKILL.
#SBATCH --mem=0
#SBATCH --requeue
# Soft-stop: watchdog ends the job soon after ROMS/TOMS: DONE (see launch below).


# InaCAWO portable env + hindcast conda
if [[ -f "${HOME}/inacawo-iht/setup_env.bash" ]]; then
  # shellcheck disable=SC1091
  source "${HOME}/inacawo-iht/setup_env.bash"
elif [[ -n "${WORK_BASE:-}" && -f "${WORK_BASE}/setup_env.bash" ]]; then
  # shellcheck disable=SC1091
  source "${WORK_BASE}/setup_env.bash"
else
  echo "ERROR: missing setup_env.bash" >&2
  exit 1
fi

set -x

date

source $COAWST_ENV
source /etc/profile.d/modules.sh
module purge
module load compiler/2022.0.2 mpi/2021.5.1
module list

which mpiexec
which mpirun

# set -x
env | grep SLURM

pwd

ulimit -c unlimited
ulimit -a
##limit memoryuse unlimited
##limit stacksize unlimited

# OpenMP settings
export OMP_NUM_THREADS=1

# Drop conda/mpich libfabric from the loader path — it conflicts with Intel MPI
# (hindcast env ships libfabric.so + libmpich.so).
if [[ -n "${LD_LIBRARY_PATH:-}" ]]; then
  _ld_clean=""
  IFS=':' read -r -a _ld_parts <<< "${LD_LIBRARY_PATH}"
  for _p in "${_ld_parts[@]}"; do
    [[ -z "${_p}" ]] && continue
    case "${_p}" in
      *miniforge*|*/envs/hindcast*|*conda*) continue ;;
    esac
    _ld_clean="${_ld_clean:+${_ld_clean}:}${_p}"
  done
  export LD_LIBRARY_PATH="${_ld_clean}"
  unset _ld_clean _ld_parts _p
fi

# Ensure NetCDF ($LIBDEP) is visible; do not force I_MPI_OFI_LIBRARY_INTERNAL /
# FI_PROVIDER_PATH here — that combo with verbs@88 triggered forrtl overflows
# (562324+). Job 562296 (verbs, no those pins) reached START_EM before PLD.
if [[ -z "${I_MPI_ROOT:-}" ]]; then
  echo "ERROR: I_MPI_ROOT unset after module load mpi" >&2
  exit 1
fi
if [[ -n "${LIBDEP:-}" ]]; then
  case ":${LD_LIBRARY_PATH:-}:" in
    *":${LIBDEP}:"*) ;;
    *) export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:+${LD_LIBRARY_PATH}:}${LIBDEP}" ;;
  esac
fi

# Clear conflicting fabric knobs; fabric block below sets the ones we want.
unset I_MPI_HYDRA_IFACE FI_MLX_TLS I_MPI_OFI_PROVIDER FI_PROVIDER UCX_TLS \
  FI_VERBS_IFACE I_MPI_FALLBACK || true

# Preflight: refuse conda/mpich fabric leakage into coawstM
_bad_ld="$(ldd ./coawstM 2>/dev/null | grep -E 'miniforge|/envs/hindcast|libmpich|conda' || true)"
if [[ -n "${_bad_ld}" ]]; then
  echo "ERROR: coawstM resolves poisoned libs:" >&2
  echo "${_bad_ld}" >&2
  exit 1
fi
echo "[hindcast-mpi] ldd preflight OK (no conda/mpich)"
ldd ./coawstM 2>/dev/null | grep -E 'libmpi\.so|libfabric|libnetcdf' || true
unset _bad_ld

# Intel MPI fabrics — default matches restgen_production oper 88×96 template
# (proven on DEV1: mlx + UCX_TLS=all, I_MPI_OFI_LIBRARY_INTERNAL=0, NO FI_MLX_TLS).
# Source: restgen_production/scripts/cawo_analy/slurm_cawo_3wrsp_*88x96.template.bash
# Override experiments: IHT_DEV1_FABRIC=verbs|mlx_dc
_part="${SLURM_JOB_PARTITION:-${IHT_SLURM_PARTITION:-unknown}}"
_dev1_fab="${IHT_DEV1_FABRIC:-restgen}"

_iht_fabric_restgen() {
  echo "[hindcast-mpi] partition=${_part} → fabric=restgen-mlx (UCX_TLS=all, OFI_INTERNAL=0)"
  # UCX (keep restgen typo UCX_NET_DEVICESi for bit-identical env)
  export UCX_NET_DEVICESi=mlx5_0:1
  export UCX_NET_DEVICES=mlx5_0:1
  export UCX_IB_ADDR_TYPE=ib_global
  export UCX_TLS=all
  export UCX_IB_RC_TM_ENABLE=y
  export UCX_RC_MLX5_TM_ENABLE=y
  export UCX_IB_PCI_RELAXED_ORDERING=off
  export UCX_PROTO_ENABLE=n
  # Intel MPI / libfabric
  export I_MPI_FABRICS=shm:ofi
  export FI_PROVIDER=mlx
  export I_MPI_OFI_PROVIDER=mlx
  export FI_VERBS_IFACE=ib0
  export I_MPI_OFI_LIBRARY_INTERNAL=0
  export I_MPI_SHM=clx_avx2
  export I_MPI_MALLOC=1
  export I_MPI_SHM_HEAP=1
  export I_MPI_FALLBACK=0
  export I_MPI_HYDRA_IFACE=ib0
  export I_MPI_HYDRA_PMI_CONNECT=alltoall
  # FI_MLX_TLS intentionally unset (restgen comments it out; dc AV fails on DEV1)
  unset FI_MLX_TLS || true
  export I_MPI_HYDRA_BRANCH_COUNT=-1
  export I_MPI_EXTRA_FILESYSTEM=on
  export I_MPI_EXTRA_FILESYSTEM_FORCE=lustre
}

case "${_dev1_fab}" in
  restgen|"")
    _iht_fabric_restgen
    ;;
  verbs)
    echo "[hindcast-mpi] partition=${_part} → fabric=verbs (override)"
    export I_MPI_FABRICS=shm:ofi
    export I_MPI_SHM=clx_avx2
    export I_MPI_MALLOC=1
    export I_MPI_SHM_HEAP=1
    export I_MPI_HYDRA_PMI_CONNECT=alltoall
    export I_MPI_HYDRA_BRANCH_COUNT=4
    export FI_PROVIDER=verbs
    ;;
  mlx_dc)
    echo "[hindcast-mpi] partition=${_part} → fabric=mlx + FI_MLX_TLS=dc (may AV-fail on DEV1)"
    export I_MPI_FABRICS=shm:ofi
    export FI_PROVIDER=mlx
    export I_MPI_OFI_PROVIDER=mlx
    export I_MPI_HYDRA_IFACE=ib0
    export FI_MLX_TLS=dc,dc_x,shm,self
    export I_MPI_OFI_LIBRARY_INTERNAL=0
    ;;
  *)
    echo "ERROR: unknown IHT_DEV1_FABRIC=${_dev1_fab} (use restgen|verbs|mlx_dc)" >&2
    exit 2
    ;;
esac
unset _dev1_fab

export KMP_AFFINITY=verbose

# Disable Slurm CPU binding
export SLURM_CPU_BIND=NONE

# NP follows allocation; hostfile like restgen production launch.
_NP="${SLURM_NTASKS:-$(( ${SLURM_JOB_NUM_NODES:-88} * ${SLURM_NTASKS_PER_NODE:-96} ))}"
_PPN="${SLURM_NTASKS_PER_NODE:-96}"
echo "[hindcast-mpi] mpiexec np=${_NP} ppn=${_PPN} nodes=${SLURM_JOB_NUM_NODES:-?}"
nodeset -e $SLURM_NODELIST | tr ' ' '\n' > ./hostfile.${SLURM_JOBID}

# Slurm stdout for this job (where ROMS/TOMS: DONE appears).
_log="${SLURM_JOB_STDOUT:-${SLURM_SUBMIT_DIR:-.}/log_run_${SLURM_JOBID}.out}"
# After ocean DONE, allow WRF/coupler a short grace window before force-stop.
# MPI often hangs in finalize / stdout flush after success (seen on DEV1 88×96).
_grace_after_roms="${IHT_MODEL_DONE_GRACE_SEC:-180}"
_poll_sec="${IHT_MODEL_DONE_POLL_SEC:-15}"
_wrf_wait_sec="${IHT_MODEL_WRF_WAIT_SEC:-600}"

_iht_kill_mpi_tree() {
  local pid="$1"
  [[ -n "${pid}" ]] || return 0
  if kill -0 "${pid}" 2>/dev/null; then
    echo "[hindcast-mpi] terminating mpiexec pid=${pid} (model finished or hung after DONE)"
    kill -TERM "${pid}" 2>/dev/null || true
    local _i
    for _i in 1 2 3 4 5 6 7 8 9 10; do
      kill -0 "${pid}" 2>/dev/null || return 0
      sleep 1
    done
    kill -KILL "${pid}" 2>/dev/null || true
    # Hydra/srun children sometimes detach from the parent pid
    pkill -KILL -P "${pid}" 2>/dev/null || true
  fi
}

set +e
set +x
mpiexec.hydra -bootstrap slurm -np "${_NP}" -ppn "${_PPN}" \
  -hostfile ./hostfile.${SLURM_JOBID} ./coawstM ./coupling_cawo.in &
_mpi_pid=$!
echo "[hindcast-mpi] mpiexec started pid=${_mpi_pid}; watchdog log=${_log}"

_forced_done=0
_roms_seen=0
_wrf_seen=0
_t0=$(date +%s)
while kill -0 "${_mpi_pid}" 2>/dev/null; do
  if [[ -f "${_log}" ]]; then
    if [[ "${_roms_seen}" -eq 0 ]] && grep -m1 -q 'ROMS/TOMS: DONE' "${_log}" 2>/dev/null; then
      _roms_seen=1
      _roms_t=$(date +%s)
      echo "[hindcast-mpi] detected ROMS/TOMS: DONE at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    fi
    if [[ "${_roms_seen}" -eq 1 && "${_wrf_seen}" -eq 0 ]] \
      && grep -m1 -q 'wrf: SUCCESS COMPLETE WRF' "${_log}" 2>/dev/null; then
      _wrf_seen=1
      _wrf_t=$(date +%s)
      echo "[hindcast-mpi] detected wrf: SUCCESS COMPLETE WRF"
    fi
  fi
  if [[ "${_roms_seen}" -eq 1 ]]; then
    _now=$(date +%s)
    _since_roms=$((_now - _roms_t))
    # Both markers: brief grace then stop (avoid MPI finalize / stdout hang).
    if [[ "${_wrf_seen}" -eq 1 ]]; then
      _since_wrf=$((_now - _wrf_t))
      if [[ "${_since_wrf}" -ge "${_grace_after_roms}" ]]; then
        echo "[hindcast-mpi] model success (ROMS+WRF); force-stopping MPI after ${_grace_after_roms}s grace"
        _iht_kill_mpi_tree "${_mpi_pid}"
        _forced_done=1
        break
      fi
    elif [[ "${_since_roms}" -ge "${_wrf_wait_sec}" ]]; then
      echo "[hindcast-mpi] ROMS DONE but WRF SUCCESS not seen within ${_wrf_wait_sec}s; force-stopping MPI"
      _iht_kill_mpi_tree "${_mpi_pid}"
      _forced_done=1
      break
    fi
  fi
  sleep "${_poll_sec}"
done

wait "${_mpi_pid}"
_rc=$?
set -e
if [[ "${_forced_done}" -eq 1 ]]; then
  echo "[hindcast-mpi] watchdog ended job after model completion (mpiexec wait rc=${_rc} → treating as success)"
  _rc=0
elif [[ "${_rc}" -ne 0 ]]; then
  echo "[hindcast-mpi] mpiexec exited rc=${_rc} (no forced DONE stop)"
fi
unset _NP _PPN _mpi_pid _forced_done _roms_seen _wrf_seen _log _grace_after_roms _poll_sec _wrf_wait_sec
unset -f _iht_kill_mpi_tree 2>/dev/null || true

date

exit "${_rc}"
