#!/bin/bash
#SBATCH --partition=HDCAST
#SBATCH --job-name=HDCST-FT        #passed by script
#SBATCH --nodes=88                #passed by script
#SBATCH --ntasks-per-node=96
#SBATCH --exclusive
#SBATCH --time=50:00
#SBATCH --output=log_run_%j.out
#SBATCH --export=ALL
#SBATCH --mem=230G
#SBATCH --requeue

set -x

date

source ~/.bashrc
source $CONDA_BASE/etc/profile.d/conda.sh
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

# IntelMPI tunings
export FI_PROVIDER=mlx
export I_MPI_OFI_PROVIDER=mlx
export I_MPI_FABRICS=shm:ofi
export I_MPI_SHM=clx_avx2
export I_MPI_FALLBACK=0
export I_MPI_HYDRA_IFACE=ib0
export I_MPI_HYDRA_PMI_CONNECT=alltoall
export FI_MLX_TLS=dc,dc_x,shm,self # or replace FI_MLX_TLS by UCX_TLS
export I_MPI_HYDRA_BRANCH_COUNT=4
export I_MPI_MALLOC=1
export I_MPI_SHM_HEAP=1

export KMP_AFFINITY=verbose # do not use : ,granularity=fine,compact #

# Disable Slurm CPU binding
export SLURM_CPU_BIND=NONE

#export OMP_PLACES=
#export OMP_BIND=

#export PROFILER_DISABLE=1
#export PROFILER_UNPLUG=1

export LD_LIBRARY_PATH="$LIBDEP:$LD_LIBRARY_PATH" # LIBDEP from env

##time /opt/software/intel/oneapi/mpi/2021.5.1/bin/mpiexec -verbose -np 4608 -ppn 96 ./wrf.exe

nodeset -e $SLURM_NODELIST | tr ' ' '\n' > ./hostfile.${SLURM_JOBID}
#time mpiexec.hydra -bootstrap slurm -np 12672 -ppn 96 -hostfile ./hostfile.${SLURM_JOBID} ./coawstM Projects/CAWO_3way/input/coupling_cawo.in
#time mpiexec.hydra -bootstrap slurm -np 12672 -ppn 96 -hostfile ./hostfile.${SLURM_JOBID} ./coawstM ./coupling_cawo.in 
mpiexec.hydra -bootstrap slurm -np 8448 -ppn 96 -hostfile ./hostfile.${SLURM_JOBID} ./coawstM ./coupling_cawo.in

date

exit 0
