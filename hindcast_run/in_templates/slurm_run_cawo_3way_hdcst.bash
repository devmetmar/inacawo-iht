#!/bin/bash
# Partition: submit_days.bash always passes --partition=${IHT_SLURM_PARTITION}
# (auto HDCAST→DEV1). Keep HDCAST here only as a manual-sbatch fallback for
# accounts that are allowed on HDCAST.
#SBATCH --partition=HDCAST
#SBATCH --job-name=HDCST-FT        #passed by script
#SBATCH --nodes=88                #passed by script
#SBATCH --ntasks-per-node=96
#SBATCH --exclusive
#SBATCH --time=50:00
#SBATCH --output=log_run_%j.out
#SBATCH --export=ALL
# Full node RAM (RealMemory≈251 GiB). --mem=230G OOMs: peak MaxRSS ~242 GiB → SIGKILL.
#SBATCH --mem=0
#SBATCH --requeue


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

# Intel MPI fabrics:
#   HDCAST — production mlx + ib0 (validated on HDCAST AllowAccounts)
#   DEV1   — mlx+ib0 / FI_MLX_TLS causes OFI AV map failure for coawstM;
#            use verbs (IB) over ofi instead (validated past MPI_Init at 8×96)
_part="${SLURM_JOB_PARTITION:-${IHT_SLURM_PARTITION:-unknown}}"
export I_MPI_FABRICS=shm:ofi
export I_MPI_SHM=clx_avx2
export I_MPI_HYDRA_PMI_CONNECT=alltoall
export I_MPI_HYDRA_BRANCH_COUNT=4
export I_MPI_MALLOC=1
export I_MPI_SHM_HEAP=1
unset I_MPI_FALLBACK || true

if [[ "${_part}" == "HDCAST" ]]; then
  echo "[hindcast-mpi] partition=HDCAST → fabric=mlx/ib0"
  export FI_PROVIDER=mlx
  export I_MPI_OFI_PROVIDER=mlx
  export I_MPI_HYDRA_IFACE=ib0
  export FI_MLX_TLS=dc,dc_x,shm,self
else
  echo "[hindcast-mpi] partition=${_part} → fabric=verbs (DEV1-safe; avoids mlx/ib0 OFI AV failure)"
  unset I_MPI_HYDRA_IFACE FI_MLX_TLS I_MPI_OFI_PROVIDER || true
  export FI_PROVIDER=verbs
fi

export KMP_AFFINITY=verbose # do not use : ,granularity=fine,compact #

# Disable Slurm CPU binding
export SLURM_CPU_BIND=NONE

#export OMP_PLACES=
#export OMP_BIND=

#export PROFILER_DISABLE=1
#export PROFILER_UNPLUG=1

# NetCDF/HDF5 deps after Intel MPI libs (do not shadow libfabric)
export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:+${LD_LIBRARY_PATH}:}${LIBDEP}"

##time /opt/software/intel/oneapi/mpi/2021.5.1/bin/mpiexec -verbose -np 4608 -ppn 96 ./wrf.exe

# Prefer Slurm bootstrap alone (hostfile optional; kept for debugging)
nodeset -e $SLURM_NODELIST | tr ' ' '\n' > ./hostfile.${SLURM_JOBID}
#time mpiexec.hydra -bootstrap slurm -np 12672 -ppn 96 -hostfile ./hostfile.${SLURM_JOBID} ./coawstM Projects/CAWO_3way/input/coupling_cawo.in
#time mpiexec.hydra -bootstrap slurm -np 12672 -ppn 96 -hostfile ./hostfile.${SLURM_JOBID} ./coawstM ./coupling_cawo.in
set +e
mpiexec.hydra -bootstrap slurm -np 8448 -ppn 96 ./coawstM ./coupling_cawo.in
_rc=$?
set -e

date

exit "${_rc}"
