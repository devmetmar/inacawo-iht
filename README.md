# InaCAWO Hindcast Mode

Coupled WRF–ROMS–SWAN hindcast workflow for the CAWO domain, built on a customized [COAWST](https://www.myroms.org/projects/src/coawst/) installation. Each calendar day is run as a separate COAWST integration in its own folder (`fYYYYMMDD`), driven by ERA5 atmospheric forcing, GLORYS ocean boundary conditions, and LiveOcean-based ROMS forcing.

## Overview

The hindcast pipeline has four stages:

1. **Preprocess** — download reanalysis data and prepare WRF, ROMS, and SWAN boundary/initial conditions.
2. **Run setup** — create daily run directories, generate model input files from templates, and stage binaries and static files.
3. **Model integration** — submit one SLURM job per day and wait for ROMS to finish.
4. **Postprocess** — regrid model output onto the standard CAWO_LL025 grid with `xesmf`.

```
preprocess/          hindcast_run/              postprocess/
  get_era5    ──►      create_folders.py    ──►   post_roms2d_xesmf.py
  get_glorys           modify_dot_in.py           post_roms3d_xesmf.py
  wps_run              copy_files_for_run*.bash   post_wrf2d_xesmf.py
  get_roms_icbc        run_hindcast.bash          post_wrf3d_xesmf.py
  get_swan_bry
```

## Prerequisites

- HPC cluster with SLURM and the `HDCAST` partition.
- Intel oneAPI MPI/compiler modules (see `slurm_run_cawo_3way_hdcst.bash`).
- Conda environments:
  - `loenv` — LiveOcean forcing and preprocessing (`conda activate loenv`).
  - `cawo_post` — postprocessing with `xesmf` (see `src/conda_env/cawo_post.yml`).
  - `cdsapi` / `copernicusmarine` — data download (see `src/conda_env/`).
- Built COAWST binaries under `$MODEL_BASE` (e.g. `cawo_3way_swell_mods_no_ramp_tides`, `cawo_3way_swell_mods_ramp_tides`).
- API credentials:
  - [CDS API](https://cds.climate.copernicus.eu/) for ERA5 downloads.
  - [Copernicus Marine](https://marine.copernicus.eu/) for GLORYS downloads.

## Environment setup

Source `env` before running any scripts. It defines paths for code, scratch data, model binaries, and static inputs.

```bash
source /home/maritime_rnd/inacawo/hindcast/env
```

| Variable | Purpose |
|---|---|
| `WORK_BASE` | Working copy of hindcast scripts (default: `/home/maritime_rnd/project/hindcast`) |
| `CAWO_HINDCAST_BASE` | Scratch root for input, run, and output data |
| `CAWO_INPUT` | Downloaded and preprocessed forcing (`era5/`, `mercator/`, `wps_run/`, `roms_forcing/`, `swan_bcs/`) |
| `CAWO_HINDCAST_RUN` | Daily run directories (`fYYYYMMDD/`) |
| `CAWO_OUTPUT` | Model history output per day |
| `MODEL_BASE` | Built COAWST model binaries |
| `IN_TEMPLATES` | ROMS/SWAN/WRF input templates |
| `GRID_DATA` | Static ROMS grid data (nudging, MSL, etc.) |
| `ROMS_FORCING` | LiveOcean-generated ROMS forcing files |

Edit `env` to match your machine and scratch layout before first use.

## Directory structure

```bash
.
├── hindcast_run/          # Daily run setup and COAWST execution
│   ├── in_templates/      # ROMS, SWAN, WRF, coupling templates
│   │   └── day1/          # Alternate templates for the first integration day
│   ├── utils/             # Per-model template modifiers
│   ├── create_folders.py
│   ├── modify_dot_in.py
│   ├── copy_files_for_run.bash
│   ├── copy_files_for_run_day1.bash
│   └── run_hindcast.bash
├── postprocess/           # Regridding to CAWO_LL025 (xesmf)
├── preprocess/            # Data download and boundary-condition preparation
│   ├── get_era5/          # ERA5 surface, pressure-level, and wave downloads
│   ├── get_glorys/        # GLORYS ocean reanalysis download
│   ├── get_roms_icbc/     # ROMS IC/BC via LiveOcean forcing driver
│   ├── get_swan_bry/      # SWAN spectral boundary conditions from ERA5 waves
│   └── wps_run/           # WPS ungrib → metgrid → real
├── src/                   # LiveOcean (LO) source tree and conda env specs
│   ├── conda_env/
│   ├── LO/                # LiveOcean forcing and utilities
│   ├── LO_data/           # Grid definitions (cawo)
│   ├── LO_output/         # Forcing output (gitignored except grid metadata)
│   └── LO_user/
├── env
└── README.md
```

## Workflow

All date ranges below are examples. Edit the `start_date` / `end_date` variables in each script before submitting.

### 1. Preprocessing

Run from `$WORK_BASE/preprocess/` (or the equivalent path under this repo) after sourcing `env`.

#### ERA5 atmospheric forcing

```bash
conda activate cdsapi   # or environment with cdsapi installed
cd preprocess/get_era5

python get_era5_surface_automate.py 19950101 19950105
python get_era5_pl_automate.py       19950101 19950105
python get_era5_waves.py             19950101 19950105
```

Downloads land/surface, pressure-level, and wave fields into `$ERA5_BASE_DIR` and `$CAWO_INPUT/era5_waves/`.

#### GLORYS ocean reanalysis

```bash
conda activate copernicusmarine
cd preprocess/get_glorys

python get_glorys_reanalysis.py        19950101 19950105
python get_glorys_reanalysis_interim.py 19950101 19950105   # if needed for recent dates
```

#### WPS (WRF preprocessing)

```bash
cd preprocess/wps_run
sbatch slurm_run_ungrib.bash    # ERA5 GRIB → intermediate format
sbatch slurm_run_metgrid.bash   # Horizontally interpolate to WRF grid
sbatch slurm_run_real.bash      # WRF real.exe boundary/initial files
```

Output lands in `$WPS_RUN_DIR/era5_YYYYMMDD/real/`.

#### ROMS initial and boundary conditions

Uses the LiveOcean `driver_forcing3.py` wrapper with grid `cawo`.

```bash
conda activate loenv
cd preprocess/get_roms_icbc

# Open-boundary and grid forcing (parallel over dates)
sbatch slurm_run_ocnA0_par.bash

# GLORYS-based forcing
sbatch slurm_run_ocnGcawo_par.bash

# Day-1 only (first integration day)
sbatch slurm_run_ocnA0_day1.bash
sbatch slurm_run_ocnGcawo_day1.bash
```

Forcing files are written under `$ROMS_FORCING` (and tracked in `src/LO_output/` when using the installed `lo_tools`).

#### SWAN boundary conditions

```bash
conda activate loenv
cd preprocess/get_swan_bry
sbatch slurm_make_swan_bc.bash
```

Reads ERA5 wave GRIB from `$CAWO_INPUT/era5_waves/` and writes TPAR files to `$CAWO_INPUT/swan_bcs/`.

### 2. Hindcast run setup

```bash
source env
cd hindcast_run

# Create one folder per day
python create_folders.py 19950102 19950105

# Generate roms.in, swan.in, namelist.input from templates
python modify_dot_in.py 19950102 19950105
# First day only (uses day1/ templates):
python modify_dot_in.py 19950101 19950101 --day1

# Stage coawstM binary, WRF real output, and static files into each run folder
bash copy_files_for_run.bash          # continuing days (no_ramp_tides binary)
bash copy_files_for_run_day1.bash     # day 1 (ramp_tides binary)
```

`modify_dot_in.py` substitutes date tokens (`today`, `tomorrow`, `yesterday`, `DSTART`) and path placeholders (`ROMS_FORCING`, `STATIC_DATA`, `CAWO_OUTPUT`) in the templates. Use `--models roms swan wrf` to update a subset.

### 3. Model integration

```bash
cd hindcast_run
bash run_hindcast.bash
```

For each day in its date range, this script:

1. `cd` into `$CAWO_HINDCAST_RUN/fYYYYMMDD`.
2. Submits `slurm_run_cawo_3way_hdcst.bash` (8448 MPI ranks on `HDCAST`).
3. Polls the job log until `ROMS/TOMS: DONE` appears, then cancels the SLURM job.

Model history files are written to `$CAWO_OUTPUT/fYYYYMMDD/`.

### 4. Postprocessing

Regrid COAWST output onto the CAWO_LL025 grid (2201×1201 at 0.025°).

```bash
conda activate cawo_post
cd postprocess

sbatch slurm_run_post_roms2d.bash
sbatch slurm_run_post_roms3d.bash
sbatch slurm_run_post_wrf2d.bash
sbatch slurm_run_post_wrf3d.bash
```

| Script | Output product |
|---|---|
| `post_roms2d_xesmf.py` | OCEAN2D — surface temp, salt, currents, zeta, wave vars |
| `post_roms3d_xesmf.py` | OCEAN3D — full water-column fields |
| `post_wrf2d_xesmf.py` | MET2D — 2-D atmospheric fields |
| `post_wrf3d_xesmf.py` | MET3D — 3-D atmospheric fields |

Edit the `START_DATE`, `END_DATE`, `HIND_ROOT`, and `OUT_ROOT` variables at the top of each `slurm_run_post_*.bash` script to match your run.

## Day-1 vs continuing days

The first hindcast day differs from subsequent days:

| Aspect | Day 1 | Continuing days |
|---|---|---|
| Templates | `in_templates/day1/` | `in_templates/` |
| COAWST binary | `cawo_3way_swell_mods_ramp_tides` | `cawo_3way_swell_mods_no_ramp_tides` |
| Copy script | `copy_files_for_run_day1.bash` | `copy_files_for_run.bash` |
| ROMS forcing | `slurm_run_ocnA0_day1.bash`, `slurm_run_ocnGcawo_day1.bash` | `slurm_run_ocnA0_par.bash`, `slurm_run_ocnGcawo_par.bash` |
| `modify_dot_in.py` | add `--day1` flag | default |

## LiveOcean source (`src/`)

The `src/LO/` tree is a copy of [LiveOcean](https://github.com/parkerjco/LiveOcean) configured for the `cawo` grid. It is used primarily by `preprocess/get_roms_icbc/` for generating ROMS open-boundary and initial-condition forcing. Grid metadata lives in `src/LO_data/grids/cawo/`.

Conda environment specifications for data download and postprocessing are in `src/conda_env/`:

- `cdsapi.yml` — ERA5 CDS downloads
- `copernicusmarine.yml` — GLORYS Copernicus Marine downloads
- `cawo_post.yml` — xesmf postprocessing stack

## Notes

- **Working copy vs repo**: `env` sets `WORK_BASE` to `/home/maritime_rnd/project/hindcast`, which may be a deployed copy of this repository. Scripts are typically run from `WORK_BASE` after sourcing `env`.
- **ROMS forcing path**: `ROMS_FORCING` in `env` points to `$CAWO_INPUT/roms_forcing`. Using local `Lfun` utils instead of installed `lo_tools` can generate NetCDF forcing without updating `LO_output/results.txt`.
- **Static data**: WRF/WPS static files, SWAN bathymetry/coordinates, and ROMS grid data are read from paths defined in `env` (`WPS_STATIC_DIR`, `SWAN_STATIC`, `GRID_DATA`, etc.) and are not part of this repository.
