# Preprocess

Download and build all forcing needed for a hindcast day. Code lives here under
`$HOME/inacawo-iht/preprocess/`; writable products go to **`$CAWO_INPUT`**
(`$SCRATCH/inacawo-iht/cawo_input/`).

## Entrypoint (preferred)

```bash
# From repo root or preprocess/ (root has a thin wrapper):
./run_preprocess.bash --start YYYYMMDD --end YYYYMMDD --stage download
./run_preprocess.bash --start YYYYMMDD --end YYYYMMDD --stage download --model era5-pl
./run_preprocess.bash --start YYYYMMDD --end YYYYMMDD --stage download --overwrite
./run_preprocess.bash --start 20210404 --end 20210410 --stage download --offline
./run_preprocess.bash --start YYYYMMDD --end YYYYMMDD --stage wps
./run_preprocess.bash --start YYYYMMDD --end YYYYMMDD --stage swan
./run_preprocess.bash --start YYYYMMDD --end YYYYMMDD --stage roms
./run_preprocess.bash --start YYYYMMDD --end YYYYMMDD --stage roms --day1
./run_preprocess.bash --help
```

**`--day1` (ROMS only):** like `run_hindcast --day1` — the **first** day of
`--start`..`--end` uses day1 scripts (`ocnA0_day1` / `ocnGcawo_day1`); remaining
days use continuing scripts (`*_par`). If `start==end`, only that day is day1.
WPS/SWAN/download are unchanged by `--day1`.

**`--end` = last hindcast day (auto end+1):** each coupled day runs **12Z→12Z+1**,
so ROMS/SWAN/WPS need products for `D` and `D+1`. By default preprocess extends
the effective range to `--end + 1 day` (same `--end` as `run_hindcast`). Log line:
`requested --end=E → also preparing end+1=…`. Pass `--exact-dates` to disable
(e.g. repairing only the padding day).

`run_preprocess.bash` sources `setup_env.bash` itself, sets `IHT_START_DATE` /
`IHT_END_DATE` (and ISO/dot variants), and dispatches subdirectory scripts. Dates
are **not** edited inside SLURM files for normal use. Use `--dry-run` to print
commands only.

**SLURM stages (wps / swan / roms) wait by default:** jobs are submitted one step
at a time (WPS: ungrib → metgrid → real), and each Slurm log is followed into the
preprocess SST log until COMPLETED. Terminal still prints only the log realpath —
monitor with `tail -f <logfile>`. Pass `--no-wait` to submit and exit (WPS then
uses `afterok` dependencies).

**Partition:** auto-selects `HDCAST` if your Slurm account is in that partition’s
`AllowAccounts`; otherwise falls back to `DEV1` (avoids stuck `PENDING
(PartitionConfig)`). Override with `--partition NAME` or `IHT_SLURM_PARTITION`.

**Downloads — skip by default:** if expected outputs for `--start`..`--end` already
exist and validate (NetCDF via `ncdump -h`; GRIB via `wgrib2`/`grib_ls` or GRIB
magic bytes), that step is skipped. Pass `--overwrite` to force re-download.
Each step logs elapsed time; a timing summary (per-step + TOTAL) is printed at the end.

### Offline / shared forcing (TC Seroja)

For training on this HPC, avoid CDS/CMEMS bandwidth: use `--offline` so download
steps **symlink** from the shared tree into per-user `$CAWO_INPUT` and **never**
call the network. Missing shared files fail hard (no download fallback).

**Training window (≤7 hindcast days):** `--start 20210404 --end 20210410`.
With default end+1, products through `20210411` are linked. Incompatible with
`--overwrite`. Optional `--offline-root DIR` (default `$IHT_OFFLINE_INPUT` =
`/scratch/cawohdcst_ft2/data`); expects `era5/`, `era5_waves/`, `mercator/`
with the same layout as `$CAWO_INPUT`. Static grids/WPS remain under
`$SHARED_DATA` (`/scratch/cawohdcst_ft/data`).

```bash
source $HOME/inacawo-iht/setup_env.bash
./run_preprocess.bash --start 20210404 --end 20210410 --stage download --offline
```

**Maintainer staging (one-time, online):** write the Seroja archive into the
shared forcing tree once (credentials required), then make it group-readable.
Set `CAWO_INPUT` **before** sourcing the env (or before `run_preprocess`, which
re-sources it):

```bash
export CAWO_INPUT=/scratch/cawohdcst_ft2/data
source $HOME/inacawo-iht/setup_env.bash
./run_preprocess.bash --start 20210404 --end 20210410 --stage download
chmod -R a+rX $CAWO_INPUT/{era5/era5_2021040{4,5,6,7,8,9},era5/era5_2021041{0,1},era5_waves/era5_202104*,mercator/GLORYS*2021-04*}
```

**Auto-log (quiet):** full stdout/stderr go to
`$WORK_BASE/logs/preprocess/preprocess_<start>_<end>_<stage>_<timestamp>.log`.
The run terminal prints **only the log realpath** (absolute).
Monitor in another terminal:

```bash
tail -f /path/to/inacawo-iht/logs/preprocess/preprocess_….log
```

Ctrl+C stops local child processes and `scancel`s jobs submitted in that run.
Use `-v/--verbose` to also mirror the log here; `--no-log` disables the log file.

| `--stage` (alias) | Expands to |
|-------------------|------------|
| `all` (default) | download + wps + swan + roms |
| `download` | `era5-sfc,era5-pl,era5-waves,glorys` |
| `era5` | `era5-sfc,era5-pl,era5-waves` |
| `wps` | `ungrib,metgrid,real` |
| `roms` | `roms-a0,roms-gcawo` |

Atomic steps may be passed directly (e.g. `--stage era5-pl`) or as
`--stage download --model era5-pl`. Downloads run locally; WPS/SWAN/ROMS via `sbatch`.

## Layout

```
inacawo-iht/
  logs/preprocess/      # auto-logs ($IHT_LOG_DIR, portable under repo)
  preprocess/
    run_preprocess.bash # entrypoint
    get_era5/           # ERA5 atmosphere + waves (cdsapi)
    get_glorys/         # GLORYS ocean (copernicusmarine)
    wps_run/            # ungrib → metgrid → real (WRF IC/LBC)
    get_swan_bry/       # SWAN TPAR boundary files from ERA5 waves
    get_roms_icbc/      # ROMS IC/BC via LiveOcean (supported entrypoints)
    LO_user/            # LO user config + forcing implementations (git-tracked)
```

## Bootstrap

```bash
source $HOME/inacawo-iht/setup_env.bash   # paths + conda activate hindcast
```

Requires **personal** API credentials — see
[`src/credentials/README.md`](../src/credentials/README.md):

```bash
source $HOME/inacawo-iht/setup_env.bash \
  --cds-key 'UID:KEY' --cmems-user U --cmems-pass P
```

Vault pull is opt-in (`IHT_VAULT_CREDS=1`) for operators only.

## Typical order (manual, if not using the entrypoint)

1. `get_era5/` + `get_glorys/`
2. `wps_run/` (needs ERA5)
3. `get_swan_bry/` (needs ERA5 waves)
4. `get_roms_icbc/` (needs GLORYS + shared `GRID_DATA` + LO `varinfo.yaml`)

Before ROMS stages, `run_preprocess.bash` seeds under `$LO_DATA`:
- `grids/cawo/` ← shared `$GRID_DATA`
- `varinfo/varinfo.yaml` ← `$LO_ROMS_VARINFO` (from `$LO_ROMS_SOURCE_ALT`)

`zrfun.get_varinfo` resolves that yaml via env / `Ldir['roms_source_alt']` /
`$LO_DATA/varinfo` (not `$HOME/LO_roms_source_alt`). Note: env `VARINFO` is the
COAWST `varinfo.dat` dir for hindcast_run — different file.

SLURM scripts honor `IHT_START_DATE` / `IHT_END_DATE` (or `IHT_*_ISO` / `IHT_*_DOT`)
when set by the entrypoint; otherwise they keep built-in fallback dates.

See each subdirectory `README.md` for scripts and outputs.
