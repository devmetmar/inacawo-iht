# in_templates

Namelist and coupling templates for daily COAWST runs. Placeholders are replaced
by `hindcast_run/modify_dot_in.py` and `utils/modify_dot_in_*.py`.

## Contents

| File / dir | Role |
|------------|------|
| `namelist.input.template` | WRF |
| `roms.in.template` | ROMS (`ROMS_FORCING`, `GRID_DATA`, …) |
| `swan.in.template` | SWAN (`CAWO_INPUT/swan_bcs/…`) |
| `coupling_cawo.in.template` | MCT coupling |
| `slurm_run_cawo_3way_hdcst.bash` | Per-day SLURM job (copied into `fYYYYMMDD`) |
| `htr_iofields_list.txt` | History field list |
| `day1/` | Day-1 variants (ramp tides / startup IC) |

## Placeholders (common)

- Date tokens: `today`, `tomorrow`, `yesterday` → `YYYYMMDD`
- Paths: `CAWO_INPUT`, `ROMS_FORCING`, `GRID_DATA`, `CAWO_OUTPUT`, …

Do not hardcode usernames in templates; keep placeholders and rely on `env`.
