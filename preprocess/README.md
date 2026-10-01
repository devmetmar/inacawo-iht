# Preprocess

```
preprocess/
  get_era5/        # ERA5 (cdsapi via hindcast env)
  get_glorys/      # GLORYS (copernicusmarine via hindcast env)
  wps_run/         # WPS → real
  get_swan_bry/    # SWAN boundary from ERA5 waves
  get_roms_icbc/   # ROMS IC/BC (primary LiveOcean entrypoints)
  LO_user/         # LiveOcean user config + forcing drivers (git-tracked)
```

Bootstrap before any job:

```bash
source $HOME/inacawo-iht/setup_env.bash   # loads env + conda activate hindcast
```

`LO_user/get_lo_info.py` uses portable paths (`$HOME/inacawo-deps/LO`, `/scratch/$USER/inacawo-iht/preprocess/LO_*`).
