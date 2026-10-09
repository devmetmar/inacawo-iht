#!/bin/bash
#SBATCH --partition=HDCAST
#SBATCH --job-name=run_metgrid_loop
#SBATCH --nodes=4
#SBATCH --ntasks-per-node=32
#SBATCH --exclusive
#SBATCH --time=200:00:00
#SBATCH --output=log/run_metgrid_loop_%j.log
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
STATIC_WPS_DIR=$WPS_STATIC_DIR
WPS_RUN_BASE=$WPS_RUN_DIR
GEOGRID_FILE=$GEOGRID_FILE

format_date_parts() {
    local ymd=$1
    YYYY=${ymd:0:4}
    MM=${ymd:4:2}
    DD=${ymd:6:2}
}

current_date=$START_DATE
while [[ "$current_date" -le "$END_DATE" ]]; do
    next_date=$(date -d "$current_date +1 day" +%Y%m%d)
    echo "Processing METGRID for $current_date to $next_date"

    UNGRIB_DIR=$WPS_RUN_BASE/era5_$current_date/ungrib
    METGRID_DIR=$WPS_RUN_BASE/era5_$current_date/metgrid
    mkdir -p "$METGRID_DIR"

    # Copy required files
    cp -p $STATIC_WPS_DIR/ungrib/namelist.wps_euro_valid.ID03F3 $METGRID_DIR/namelist.wps
    cp -p $STATIC_WPS_DIR/metgrid/METGRID.TBL $METGRID_DIR/
    cp -p $STATIC_WPS_DIR/metgrid/gribmap.txt $METGRID_DIR/
    cp -p $STATIC_WPS_DIR/metgrid/metgrid.exe $METGRID_DIR/
    cp -p $GEOGRID_FILE $METGRID_DIR/geo_em.d01.nc

    # Link FILE* from ungrib
    cd "$UNGRIB_DIR" || { echo "Missing ungrib dir $UNGRIB_DIR"; current_date=$(date -d "$current_date +1 day" +%Y%m%d); continue; }
    for j in FILE*; do
        rm -f "$METGRID_DIR/$j"
        ln -s "$UNGRIB_DIR/$j" "$METGRID_DIR/$j"
    done
    cp -p "$UNGRIB_DIR/TAVGSFC" "$METGRID_DIR/" 2>/dev/null || true

    # Edit namelist.wps dates
    format_date_parts "$current_date"
    BYYYY=$YYYY; BMM=$MM; BDD=$DD; CYCLE=12
    format_date_parts "$next_date"
    EYYYY=$YYYY; EMM=$MM; EDD=$DD; CYCLE2=12

    cd "$METGRID_DIR"
    sed -i "s/YYYY1/$BYYYY/g" namelist.wps
    sed -i "s/YYYY2/$EYYYY/g" namelist.wps
    sed -i "s/MM1/$BMM/g" namelist.wps
    sed -i "s/MM2/$EMM/g" namelist.wps
    sed -i "s/DD1/$BDD/g" namelist.wps
    sed -i "s/DD2/$EDD/g" namelist.wps
    sed -i "s/CY1/$CYCLE/g" namelist.wps
    sed -i "s/CY2/$CYCLE2/g" namelist.wps

    chmod 777 METGRID.TBL

    # MPI sizing from actual Slurm allocation (DEV1 may be 1 node)
    NNODES="${SLURM_JOB_NUM_NODES:-4}"
    PPN="${SLURM_NTASKS_PER_NODE:-32}"
    NTASKS="${SLURM_NTASKS:-$((NNODES * PPN))}"

    ulimit -s 3200000
    ulimit -m unlimited
    ulimit -v unlimited
    ulimit -d unlimited
    export OMP_NUM_THREADS=1
    export I_MPI_MALLOC=1
    export I_MPI_SHM_HEAP=1
    export KMP_AFFINITY=verbose
    export SLURM_CPU_BIND=NONE

    # HDCAST: InfiniBand/mlx. DEV1 (or single-node): TCP/shm — mlx/ib0 fails on DEV1.
    if [[ "${IHT_SLURM_PARTITION:-HDCAST}" == "HDCAST" && "${NNODES}" -gt 1 ]]; then
      export FI_PROVIDER=mlx
      export I_MPI_OFI_PROVIDER=mlx
      export I_MPI_FABRICS=shm:ofi
      export I_MPI_SHM=clx_avx2
      export I_MPI_HYDRA_IFACE=ib0
      export I_MPI_HYDRA_PMI_CONNECT=alltoall
      export FI_MLX_TLS="dc,dc_x,shm,self"
      export I_MPI_HYDRA_BRANCH_COUNT=4
    else
      echo "[metgrid] DEV1/single-node MPI fabrics (tcp/shm); n=${NTASKS} ppn=${PPN} nodes=${NNODES}"
      unset I_MPI_HYDRA_IFACE FI_MLX_TLS I_MPI_OFI_PROVIDER || true
      export FI_PROVIDER=tcp
      export I_MPI_FABRICS=shm:tcp
      export I_MPI_FALLBACK=1
    fi

    # Run metgrid — fail the job if MPI or products fail
    if ! time mpiexec.hydra -bootstrap slurm -n "${NTASKS}" -ppn "${PPN}" ./metgrid.exe; then
      echo "ERROR: metgrid.exe failed for ${current_date}" >&2
      exit 1
    fi
    if ! compgen -G "${METGRID_DIR}/met_em.d01*" >/dev/null; then
      echo "ERROR: no met_em.d01* after metgrid for ${current_date}" >&2
      exit 1
    fi

    current_date=$(date -d "$current_date +1 day" +%Y%m%d)
done

