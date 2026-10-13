# get_swan_bry

Build SWAN open-boundary TPAR files from ERA5 wave downloads.

Each calendar day is **independent** and runs as a Slurm array task
(`START + SLURM_ARRAY_TASK_ID`). `run_preprocess.bash` sets
`--array=0-(NDAYS-1)%8`.

## Prerequisites

```bash
source $HOME/inacawo-iht/setup_env.bash
# ERA5 waves present under $CAWO_INPUT/era5_waves
```

## Files

| File | Role |
|------|------|
| `make_swan_bc.py` | Reads `$CAWO_INPUT/era5_waves`, writes `$CAWO_INPUT/swan_bcs` |
| `slurm_make_swan_bc.bash` | SLURM array wrapper (one day per task) |

Logs: `log/run_swan_bc_%A_%a.log`.

## Usage

```bash
./run_preprocess.bash --start YYYYMMDD --end YYYYMMDD --only swan
# or
cd $WORK_BASE/preprocess/get_swan_bry
export IHT_START_DATE=20251231 IHT_END_DATE=20260105
sbatch --array=0-5%8 slurm_make_swan_bc.bash
```

Boundary files are copied into daily run folders by
`hindcast_run/copy_files_for_run*.bash` and referenced from `swan.in` templates
via the `CAWO_INPUT` placeholder.
