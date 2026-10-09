# get_era5

Download ERA5 fields for the CAWO domain via **cdsapi** (`hindcast` conda env).

## Prerequisites

```bash
source $HOME/inacawo-iht/setup_env.bash
# Personal ~/.cdsapirc — see ../../src/credentials/README.md
#   source setup_env.bash --cds-key 'UID:KEY' ...
```

## Scripts

| Script | Purpose | Output under `$CAWO_INPUT` |
|--------|---------|----------------------------|
| `get_era5_surface_automate.py` | Surface / soil / SST fields | `era5/era5_YYYYMMDD/` |
| `get_era5_pl_automate.py` | Pressure-level fields | `era5/era5_YYYYMMDD/` |
| `get_era5_waves.py` | Wave fields for SWAN BCs | `era5_waves/era5_YYYYMMDD/` |

## Usage

```bash
cd $WORK_BASE/preprocess/get_era5
python get_era5_surface_automate.py YYYYMMDD YYYYMMDD
python get_era5_pl_automate.py YYYYMMDD YYYYMMDD
python get_era5_waves.py YYYYMMDD YYYYMMDD
```

Dates are inclusive. Surface+PL products feed `wps_run/`; waves feed `get_swan_bry/`.
