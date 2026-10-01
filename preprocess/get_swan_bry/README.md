# get_swan_bry

Build SWAN open-boundary TPAR files from ERA5 wave downloads.

## Prerequisites

```bash
source $HOME/inacawo-iht/setup_env.bash
# ERA5 waves present under $CAWO_INPUT/era5_waves
```

## Files

| File | Role |
|------|------|
| `make_swan_bc.py` | Reads `$CAWO_INPUT/era5_waves`, writes `$CAWO_INPUT/swan_bcs` |
| `slurm_make_swan_bc.bash` | SLURM wrapper (sources `setup_env.bash`) |

## Usage

Edit dates in the SLURM script (or call Python directly), then:

```bash
cd $WORK_BASE/preprocess/get_swan_bry
sbatch slurm_make_swan_bc.bash
```

Boundary files are copied into daily run folders by
`hindcast_run/copy_files_for_run*.bash` and referenced from `swan.in` templates
via the `CAWO_INPUT` placeholder.
