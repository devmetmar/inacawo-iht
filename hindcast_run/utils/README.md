# utils

Helpers used by `hindcast_run/modify_dot_in.py` to rewrite model namelists for
each calendar day.

| Module | Edits |
|--------|-------|
| `modify_dot_in_roms.py` | `roms.in` — forcing paths, dates, output dirs |
| `modify_dot_in_swan.py` | `swan.in` — dates + `CAWO_INPUT` BCs |
| `modify_dot_in_wrf.py` | WRF namelist / related paths |

All expect `setup_env.bash` already sourced (`CAWO_HINDCAST_RUN`, `CAWO_INPUT`,
`IN_TEMPLATES`, …).
