# InaCAWO Hindcast (`inacawo-iht`)

Reproducible WRF–ROMS–SWAN hindcast workflow for the CAWO domain (COAWST).
Each calendar day runs as a separate integration (`fYYYYMMDD`).

## Companion repos

| Repo | Role |
|------|------|
| `$HOME/inacawo-deps` | Conda env (`hindcast.yml`) + LiveOcean code (`LO/`) |
| `$HOME/inacawo-iht` | **This repo** — preprocess / run / postprocess scripts |
| `$HOME/inacawo-src` | Built COAWST trees (ramp / no-ramp binaries) |

## One-time setup (new machine)

```bash
# 1) Clone
git clone <inacawo-deps-url>  $HOME/inacawo-deps
git clone <inacawo-iht-url>   $HOME/inacawo-iht
# (+ inacawo-src as needed)

# 2) Conda env (must run from inacawo-deps so ./LO/lo_tools resolves)
cd $HOME/inacawo-deps
mamba env create -f hindcast.yml
conda activate hindcast

# 3) Scratch layout (created as needed by scripts)
mkdir -p /scratch/$USER/LO_data /scratch/$USER/LO_output
mkdir -p /scratch/$USER/inacawo/cawo_hindcast

# 4) API credentials
#    ~/.cdsapirc  (ERA5 / CDS)
#    copernicusmarine login  (GLORYS)
```

## Environment bootstrap

Every SLURM/interactive script should load:

```bash
source $HOME/inacawo-iht/setup_env.bash
```

That sources `env` (portable `$HOME` / `/scratch/$USER` paths) and `conda activate hindcast`.

Key variables (see `env`):

| Variable | Meaning |
|----------|---------|
| `WORK_BASE` | `$HOME/inacawo-iht` |
| `SCRATCH` | `/scratch/$USER` |
| `MODEL_BASE` | `$HOME/inacawo-src` |
| `CAWO_HINDCAST_BASE` | `$SCRATCH/inacawo/cawo_hindcast` |
| `LO` / `LO_USER` | deps code / `preprocess/LO_user` |
| `LO_DATA` / `LO_OUTPUT` | `$SCRATCH/LO_{data,output}` |
| `ROMS_FORCING`, `GRID_DATA`, `ERA5_BASE_DIR`, `GLORYS_BASE_DIR` | preprocess I/O |

Shared site statics (WPS/WRF geog) default under `/scratch/cawohdcst_ft/...` and can be overridden:

```bash
export WPS_STATIC_DIR=/path/to/wps_static
export WRF_STATIC_DIR=/path/to/wrf_static
```

## Directory layout

```
inacawo-iht/
  setup_env.bash          # source this first
  env                     # portable path definitions
  preprocess/
    get_era5/             # ERA5 download
    get_glorys/           # GLORYS download
    wps_run/              # ungrib → metgrid → real
    get_swan_bry/         # SWAN TPAR BCs
    get_roms_icbc/        # ROMS IC/BC wrappers (primary LO entrypoints)
    LO_user/              # LiveOcean user config + forcing drivers (git-tracked)
  hindcast_run/           # daily folders, templates, run driver
  postprocess/            # xesmf regrid to CAWO_LL025
  README.md
```

## Workflow

Always:

```bash
source $HOME/inacawo-iht/setup_env.bash
cd $WORK_BASE
```

Use **`hindcast`** for all stages (download, LO forcing, postprocess). Edit date ranges inside each SLURM script before submitting.

### 1. Preprocess

```bash
cd preprocess/get_era5        # ERA5
python get_era5_surface_automate.py   # (or site scripts)
cd ../get_glorys              # GLORYS
python get_glorys_reanalysis.py
cd ../wps_run
sbatch slurm_run_ungrib.bash && sbatch slurm_run_metgrid.bash && sbatch slurm_run_real.bash
cd ../get_swan_bry
sbatch slurm_make_swan_bc.bash
cd ../get_roms_icbc           # LiveOcean ROMS IC/BC
sbatch slurm_run_ocnA0_day1.bash      # day 1
sbatch slurm_run_ocnGcawo_day1.bash
sbatch slurm_run_ocnA0_par.bash       # continuing days
sbatch slurm_run_ocnGcawo_par.bash
```

LiveOcean paths come from `preprocess/LO_user/get_lo_info.py` (and `get_roms_icbc/utils/get_lo_info.py` for the local utils import).

### 2. Run setup + model

```bash
cd hindcast_run
python create_folders.py
python modify_dot_in.py          # add --day1 for first day
bash copy_files_for_run_day1.bash   # or copy_files_for_run.bash
bash run_hindcast.bash
```

Day-1 uses ramp-tides binary + `in_templates/day1/`; continuing days use no-ramp + default templates.

### 3. Postprocess

```bash
cd postprocess
sbatch slurm_run_post_roms2d.bash
sbatch slurm_run_post_roms3d.bash
sbatch slurm_run_post_wrf2d.bash
sbatch slurm_run_post_wrf3d.bash
```

## LiveOcean (preprocess only)

| Piece | Location |
|-------|----------|
| Code (`lo_tools`) | `$HOME/inacawo-deps/LO` via `hindcast.yml` |
| User config / drivers | `preprocess/LO_user/` |
| Wrappers | `preprocess/get_roms_icbc/` |
| Data / output | `/scratch/$USER/LO_data`, `/scratch/$USER/LO_output` |

## Notes

- Prefer `get_roms_icbc/` SLURM scripts as the supported entrypoints; `LO_user/forcing/` holds the forcing implementations they call or mirror.
- Do not hardcode usernames; paths go through `env` / `setup_env.bash`.
- Static WRF/WPS/SWAN assets are **not** in this repo — set via `env` overrides.
