# hindcast_run

Prepare daily COAWST run directories (`fYYYYMMDD`), fill namelists, stage inputs,
and submit the 3-way model.

## Prerequisites

```bash
source $HOME/inacawo-iht/setup_env.bash
# preprocess complete: WPS, SWAN BCs, ROMS forcing under $CAWO_INPUT
# coawstM: $MODEL_BASE/binaries/{ramp_tides,no_ramp_tides}/ (from inacawo-src)
```

Scratch run root: **`$CAWO_HINDCAST_RUN`** (`$CAWO_HINDCAST_BASE/cawo_hindcast_run`).

## Entrypoint (preferred)

```bash
# From repo root or hindcast_run/
./run_hindcast.bash --start YYYYMMDD --end YYYYMMDD --day1
./run_hindcast.bash --start YYYYMMDD --end YYYYMMDD              # continuing only
./run_hindcast.bash --start YYYYMMDD --end YYYYMMDD --stage setup
./run_hindcast.bash --start YYYYMMDD --end YYYYMMDD --stage submit --dry-run
./run_hindcast.bash --help
```

`run_hindcast.bash` sources `setup_env.bash`, exports `IHT_*` dates, and runs
stages in order. Quiet SST log under
`$WORK_BASE/logs/hindcast/hindcast_<start>_<end>_….log` (terminal prints
realpath only). Monitor with `tail -f <logfile>`. Ctrl+C stops children and
`scancel`s jobs submitted in that run.

| `--stage` | Expands to |
|-----------|------------|
| `all` (default) | `folders`, `namelist`, `copy`, `submit` |
| `setup` | `folders`, `namelist`, `copy` |
| atomic | `folders` / `namelist` / `copy` / `submit` |

**`--day1`:** first day of the range uses day1 templates + ramp-tides binary;
remaining days use continuing templates + no-ramp. Without `--day1`, the whole
range is continuing (needs prior-day restart under `$CAWO_OUTPUT`).

**Partition:** auto-selects `HDCAST` if your Slurm account is allowed, else
`DEV1` (avoids stuck `PENDING (PartitionConfig)`). Override with `--partition`
or `IHT_SLURM_PARTITION`.

**MPI fabric:** HDCAST → `mlx`/`ib0`; DEV1 → `verbs` (same IB hardware;
`mlx`+`ib0` triggers OFI AV map failure for `coawstM` on DEV1). Conda
`libfabric`/`mpich` are stripped from `LD_LIBRARY_PATH` before launch.

## Layout

```
hindcast_run/
  run_hindcast.bash          # entrypoint (preferred)
  create_folders.py          # make fYYYYMMDD dirs
  modify_dot_in.py           # fill namelists from templates
  copy_files_for_run_day1.bash
  copy_files_for_run.bash
  submit_days.bash           # per-day sbatch + DONE wait (called by entrypoint)
  in_templates/              # namelist / swan / roms / coupling templates
  utils/                     # modify_dot_in_{roms,swan,wrf}.py
```

## Manual steps (if not using the entrypoint)

Dates via CLI for Python; `IHT_START_DATE` / `IHT_END_DATE` (YYYYMMDD) for
copy/submit scripts (hardcoded fallbacks remain for ad-hoc edits):

```bash
cd $WORK_BASE/hindcast_run
python create_folders.py YYYYMMDD YYYYMMDD
python modify_dot_in.py YYYYMMDD YYYYMMDD --day1   # or omit --day1
export IHT_START_DATE=YYYYMMDD IHT_END_DATE=YYYYMMDD
bash copy_files_for_run_day1.bash   # or copy_files_for_run.bash
bash submit_days.bash
```

- **Day 1:** ramp-tides binary + `in_templates/day1/`
- **Later days:** no-ramp binary + default `in_templates/`

Per-day job template: `in_templates/slurm_run_cawo_3way_hdcst.bash`
(sources `setup_env.bash` then `$COAWST_ENV`).
