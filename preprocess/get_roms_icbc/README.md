# get_roms_icbc

**Supported** LiveOcean entrypoints for ROMS initial / boundary / climatology
forcing (ocnA0 + ocnGcawo). Prefer these SLURM scripts over older copies under
`LO_user/driver/` or `LO_user/forcing/*/slurm_*`.

## Prerequisites

```bash
source $HOME/inacawo-iht/setup_env.bash
# GLORYS under $GLORYS_BASE_DIR; grids under $GRID_DATA (shared by default)
```

`run_preprocess.bash --stage roms` auto-links `$GRID_DATA/{grid.nc,S_COORDINATE_INFO.csv,...}`
into `$LO_DATA/grids/cawo/` (required by LiveOcean ocnA0). Without that link,
ocnA0 fails looking for `LO_data/grids/cawo/grid.nc`, and ocnGcawo then fails
looking for `roms_forcing/fYYYYMMDD/ocnA0/ocean_clm.nc`.

Paths:

| Var | Typical value |
|-----|----------------|
| `LO` | `$HOME/inacawo-deps/LO` |
| `LO_USER` | `$HOME/inacawo-iht/preprocess/LO_user` |
| `LO_DATA` / `LO_OUTPUT` | `$CAWO_INPUT/LO_{data,output}` |
| `GRID_DATA` | `/scratch/cawohdcst_ft/data/grids` (shared) |
| `ROMS_FORCING` | `$CAWO_INPUT/roms_forcing` (writable) |

## SLURM entrypoints

| Script | When |
|--------|------|
| `slurm_run_ocnA0_day1.bash` | First day — ocnA0 (`-s new`) |
| `slurm_run_ocnGcawo_day1.bash` | First day — GLORYS→ROMS (ocnG) |
| `slurm_run_ocnA0_par.bash` | Continuing days — ocnA0 |
| `slurm_run_ocnGcawo_par.bash` | Continuing days — ocnG |

Prefer `run_preprocess.bash --stage roms --day1 --start … --end …`: it runs
day1 scripts for `--start`, then `*_par` for `start+1`..`--end` (same split as
hindcast). Dates come from `IHT_*` — no need to edit SLURM files.

## Python helpers

- `make_forcing_main_nobio.py` — ocnA0
- `make_forcing_glorys_linear.py` / `_parallel.py` — ocnGcawo
- `driver_forcing3.py` — driver glue
- `utils/get_lo_info.py` — LO path dict (mirrors `LO_user/get_lo_info.py`)

Outputs land under `$ROMS_FORCING/fYYYYMMDD/...` and are wired into `roms.in`
via `hindcast_run` templates (`ROMS_FORCING` placeholder).
