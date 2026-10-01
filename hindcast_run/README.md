# hindcast_run

Prepare daily COAWST run directories (`fYYYYMMDD`), fill namelists, stage inputs,
and submit the 3-way model.

## Prerequisites

```bash
source $HOME/inacawo-iht/setup_env.bash
# preprocess complete: WPS, SWAN BCs, ROMS forcing under $CAWO_INPUT
# model tree at $MODEL_BASE (see $COAWST_ENV / built binaries)
```

Scratch run root: **`$CAWO_HINDCAST_RUN`** (`$CAWO_HINDCAST_BASE/cawo_hindcast_run`).

## Layout

```
hindcast_run/
  create_folders.py          # make fYYYYMMDD dirs
  modify_dot_in.py           # fill namelists from templates
  copy_files_for_run_day1.bash
  copy_files_for_run.bash
  run_hindcast.bash          # submit per-day SLURM jobs
  in_templates/              # namelist / swan / roms / coupling templates
  utils/                     # modify_dot_in_{roms,swan,wrf}.py
```

## Typical sequence

```bash
cd $WORK_BASE/hindcast_run
python create_folders.py
python modify_dot_in.py --day1          # first day
# or: python modify_dot_in.py           # continuing days
bash copy_files_for_run_day1.bash       # or copy_files_for_run.bash
bash run_hindcast.bash
```

- **Day 1:** ramp-tides binary + `in_templates/day1/`
- **Later days:** no-ramp binary + default `in_templates/`

Per-day job template: `in_templates/slurm_run_cawo_3way_hdcst.bash`
(sources `setup_env.bash` then `$COAWST_ENV`).
