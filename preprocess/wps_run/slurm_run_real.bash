#!/bin/bash
#SBATCH --partition=HDCAST
#SBATCH --job-name=run_real_loop
#SBATCH --nodes=16
#SBATCH --ntasks-per-node=32
#SBATCH --exclusive
#SBATCH --time=400:00:00
#SBATCH --output=log/run_real_loop_%j.log
#SBATCH --export=ALL


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

# Override via run_preprocess.bash / IHT_* env
START_DATE="${IHT_START_DATE:-19950106}"
END_DATE="${IHT_END_DATE:-19950106}"

# Directories
STATIC_WRF_DIR=$WRF_STATIC_DIR
STATIC_EXTRA_DIR=$WRF_STATIC_EXTRA_DIR
WPS_RUN_BASE=$WPS_RUN_DIR

format_date_parts() {
    local ymd=$1
    YYYY=${ymd:0:4}
    MM=${ymd:4:2}
    DD=${ymd:6:2}
}

current_date=$START_DATE
while [[ "$current_date" -le "$END_DATE" ]]; do
    next_date=$(date -d "$current_date +1 day" +%Y%m%d)
    echo "Processing REAL for $current_date to $next_date"

    METGRID_DIR=$WPS_RUN_BASE/era5_$current_date/metgrid
    REAL_DIR=$WPS_RUN_BASE/era5_$current_date/real
    mkdir -p "$REAL_DIR"
    cd "$REAL_DIR" || exit 1

    # Copy static files
    cp -p $STATIC_EXTRA_DIR/* .
    cp -p $STATIC_WRF_DIR/v431/* .

    # Clean from previous runs
    rm -f met_em.d01*nc met_em.d02*nc rsl.* wrfout_d01* \
          wrfinput_d01 wrfbdy_d01 wrfinput_d02 wrfbdy_d02 \
          wrfhtr* wrfrst* aux* finish*

    # Link metgrid outputs — missing products are fatal (do not silently "succeed")
    if compgen -G "$METGRID_DIR/met_em.d01*" > /dev/null; then
        for f in $METGRID_DIR/met_em.d01*; do
            ln -sf "$f" "$(basename "$f")"
        done
    else
        echo "ERROR: No met_em.d01* files for $current_date (metgrid must succeed first)" >&2
        exit 1
    fi

    # Prepare namelist.input
    cp -f $STATIC_WRF_DIR/nl_templates/namelist.input.024hr_real_ID03F3_ECMWF.template_lowbdy namelist.input

    format_date_parts "$current_date"
    BYYYY=$YYYY; BMM=$MM; BDD=$DD; BHH=12
    format_date_parts "$next_date"
    EYYYY=$YYYY; EMM=$MM; EDD=$DD; EHH=12

    sed -i "s/YYYY1/$BYYYY/g" namelist.input
    sed -i "s/YYYY2/$EYYYY/g" namelist.input
    sed -i "s/MM1/$BMM/g" namelist.input
    sed -i "s/MM2/$EMM/g" namelist.input
    sed -i "s/DD1/$BDD/g" namelist.input
    sed -i "s/DD2/$EDD/g" namelist.input
    sed -i "s/HH1/$BHH/g" namelist.input
    sed -i "s/HH2/$EHH/g" namelist.input

    # MPI sizing from actual Slurm allocation
    NNODES="${SLURM_JOB_NUM_NODES:-16}"
    NPER="${SLURM_NTASKS_PER_NODE:-32}"
    NUMP="${SLURM_NTASKS:-$((NNODES * NPER))}"
    ulimit -c unlimited
    export OMP_NUM_THREADS=1
    export I_MPI_MALLOC=1
    export I_MPI_SHM_HEAP=1
    export KMP_AFFINITY=verbose
    export SLURM_CPU_BIND=NONE

    if [[ "${IHT_SLURM_PARTITION:-HDCAST}" == "HDCAST" && "${NNODES}" -gt 1 ]]; then
      export FI_PROVIDER=mlx
      export I_MPI_OFI_PROVIDER=mlx
      export I_MPI_FABRICS=shm:ofi
      export I_MPI_SHM=clx_avx2
      export I_MPI_FALLBACK=0
      export I_MPI_HYDRA_IFACE=ib0
      export I_MPI_HYDRA_PMI_CONNECT=alltoall
      export FI_MLX_TLS="dc,dc_x,shm,self"
      export I_MPI_HYDRA_BRANCH_COUNT=4
    else
      echo "[real] DEV1/single-node MPI fabrics (tcp/shm); n=${NUMP} ppn=${NPER} nodes=${NNODES}"
      unset I_MPI_HYDRA_IFACE FI_MLX_TLS I_MPI_OFI_PROVIDER || true
      export FI_PROVIDER=tcp
      export I_MPI_FABRICS=shm:tcp
      export I_MPI_FALLBACK=1
    fi

    if ! time mpiexec.hydra -bootstrap slurm -n "${NUMP}" -ppn "${NPER}" ./real.exe; then
      echo "ERROR: real.exe failed for ${current_date}" >&2
      exit 1
    fi
    if [[ ! -f wrfinput_d01 ]]; then
      echo "ERROR: no wrfinput_d01 after real for ${current_date}" >&2
      exit 1
    fi

    current_date=$(date -d "$current_date +1 day" +%Y%m%d)
done

