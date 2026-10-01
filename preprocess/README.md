# Preprocess

Download and build all forcing needed for a hindcast day. Code lives here under
`$HOME/inacawo-iht/preprocess/`; writable products go to **`$CAWO_INPUT`**
(`$SCRATCH/inacawo-iht/cawo_input/`).

## Layout

```
preprocess/
  get_era5/        # ERA5 atmosphere + waves (cdsapi)
  get_glorys/      # GLORYS ocean (copernicusmarine)
  wps_run/         # ungrib → metgrid → real (WRF IC/LBC)
  get_swan_bry/    # SWAN TPAR boundary files from ERA5 waves
  get_roms_icbc/   # ROMS IC/BC via LiveOcean (supported entrypoints)
  LO_user/         # LO user config + forcing implementations (git-tracked)
```

## Bootstrap

```bash
source $HOME/inacawo-iht/setup_env.bash   # paths + conda activate hindcast
```

Requires API credentials for downloads: `~/.cdsapirc`, `copernicusmarine login`.

## Typical order

1. `get_era5/` + `get_glorys/`
2. `wps_run/` (needs ERA5)
3. `get_swan_bry/` (needs ERA5 waves)
4. `get_roms_icbc/` (needs GLORYS + shared `GRID_DATA`)

See each subdirectory `README.md` for scripts and outputs.
