# get_glorys

Download GLORYS ocean reanalysis via **copernicusmarine** (`hindcast` conda env).

## Prerequisites

```bash
source $HOME/inacawo-iht/setup_env.bash
copernicusmarine login   # once per machine/user
```

## Scripts

| Script | Notes | Output |
|--------|-------|--------|
| `get_glorys_reanalysis.py` | Main reanalysis download | `$CAWO_INPUT/mercator/` (`$GLORYS_BASE_DIR`) |
| `get_glorys_reanalysis_interim.py` | Interim product variant | same |

## Usage

```bash
cd $WORK_BASE/preprocess/get_glorys
python get_glorys_reanalysis.py YYYYMMDD YYYYMMDD
```

Consumed later by `get_roms_icbc/` (ocnGcawo / ocnA0 forcing). Prefer env-based
credentials over hardcoding usernames in scripts.
