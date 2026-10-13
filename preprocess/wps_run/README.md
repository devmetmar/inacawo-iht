# wps_run

WPS/WRF preprocessing: **ungrib → metgrid → real**. Uses Intel stack via
`$COAWST_ENV` (after `setup_env.bash`).

Each calendar day is **independent** and runs as a Slurm array task
(`START + SLURM_ARRAY_TASK_ID`). Prefer `run_preprocess.bash`, which sets
`--array=0-(NDAYS-1)%N` and (with `--no-wait`) chains stages with
`aftercorr` so day *i* metgrid/real waits only on day *i* ungrib/metgrid.

## Prerequisites

```bash
source $HOME/inacawo-iht/setup_env.bash
# ERA5 already under $ERA5_BASE_DIR ($CAWO_INPUT/era5)
# Shared statics: $WPS_STATIC_DIR, $WRF_STATIC_DIR, $GEOGRID_FILE
```

## SLURM entrypoints

| Script | Role | Default concurrency |
|--------|------|---------------------|
| `slurm_run_ungrib.bash` | Ungrib ERA5 GRIB → intermediate | `%16` |
| `slurm_run_metgrid.bash` | Metgrid (+ link geo_em from `$GEOGRID_FILE`) | `%4` |
| `slurm_run_real.bash` | WRF `real.exe` → wrfinput / wrfbdy | `%2` |

Working dirs under **`$WPS_RUN_DIR`** (`$CAWO_INPUT/wps_run`).
Logs: `log/run_<step>_%A_%a.log`.

## Usage

Via orchestrator (recommended):

```bash
./run_preprocess.bash --start YYYYMMDD --end YYYYMMDD --only ungrib,metgrid,real
```

Manual (one day or override array):

```bash
cd $WORK_BASE/preprocess/wps_run
export IHT_START_DATE=20251231 IHT_END_DATE=20260105
sbatch --array=0-5%16 slurm_run_ungrib.bash
sbatch --array=0-5%4  --dependency=aftercorr:<ungrib_jid> slurm_run_metgrid.bash
sbatch --array=0-5%2  --dependency=aftercorr:<metgrid_jid> slurm_run_real.bash
```

Each script sources `setup_env.bash` then `$COAWST_ENV` (`module purge` + Intel).
On DEV1, `run_preprocess.bash` shrinks metgrid/real to 1 node (mlx/ib0 unavailable).
