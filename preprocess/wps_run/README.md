# wps_run

WPS/WRF preprocessing: **ungrib → metgrid → real**. Uses Intel stack via
`$COAWST_ENV` (after `setup_env.bash`).

## Prerequisites

```bash
source $HOME/inacawo-iht/setup_env.bash
# ERA5 already under $ERA5_BASE_DIR ($CAWO_INPUT/era5)
# Shared statics: $WPS_STATIC_DIR, $WRF_STATIC_DIR, $GEOGRID_FILE
```

## SLURM entrypoints

| Script | Role |
|--------|------|
| `slurm_run_ungrib.bash` | Ungrib ERA5 GRIB → intermediate |
| `slurm_run_metgrid.bash` | Metgrid (+ link geo_em from `$GEOGRID_FILE`) |
| `slurm_run_real.bash` | WRF `real.exe` → met_em / wrfinput / wrfbdy |

Working dirs under **`$WPS_RUN_DIR`** (`$CAWO_INPUT/wps_run`).

## Usage

Edit date ranges inside each script, then:

```bash
cd $WORK_BASE/preprocess/wps_run
sbatch slurm_run_ungrib.bash
sbatch slurm_run_metgrid.bash   # after ungrib
sbatch slurm_run_real.bash      # after metgrid
```

Each script sources `setup_env.bash` then `$COAWST_ENV` (`module purge` + Intel).
