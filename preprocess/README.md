# Preprocess

Hindcast preprocessing stages. LiveOcean forcing is part of this stage.

```
preprocess/
  get_era5/        # ERA5 download (cdsapi)
  get_glorys/      # GLORYS download (copernicusmarine)
  wps_run/         # WPS → real
  get_swan_bry/    # SWAN boundary from ERA5 waves
  get_roms_icbc/   # ROMS IC/BC wrappers
  LO_user/         # LiveOcean user config + forcing drivers
```

`LO_user/get_lo_info.py` points at:

- code: `$HOME/inacawo-deps/LO`
- data: `/scratch/$USER/LO_data`
- output: `/scratch/$USER/LO_output`
