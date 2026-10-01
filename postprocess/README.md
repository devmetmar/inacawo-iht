# postprocess

Regrid hindcast history to the CAWO LL0.25 analysis grid with **xesmf**
(`hindcast` conda env).

## Prerequisites

```bash
source $HOME/inacawo-iht/setup_env.bash
# model output under $CAWO_OUTPUT
```

| Var | Role |
|-----|------|
| `CAWO_OUTPUT` | Raw model output (`$CAWO_HINDCAST_BASE/cawo_output`) |
| `CAWO_POST` | Postprocessed products (`$CAWO_HINDCAST_BASE/cawo_post`) |

## SLURM entrypoints

| Script | Product (under `$CAWO_POST`) |
|--------|------------------------------|
| `slurm_run_post_roms2d.bash` | `ocean2d/` |
| `slurm_run_post_roms3d.bash` | `ocean3d/` |
| `slurm_run_post_wrf2d.bash` | WRF 2-D |
| `slurm_run_post_wrf3d.bash` | WRF 3-D |

Each is a date array job — edit `START_DATE` / `END_DATE` / `#SBATCH --array` inside
the script before submitting.

## Python modules

`post_roms2d_xesmf.py`, `post_roms3d_xesmf.py`, `post_wrf2d_xesmf.py`,
`post_wrf3d_xesmf.py` — called by the SLURM wrappers.

```bash
cd $WORK_BASE/postprocess
sbatch slurm_run_post_roms2d.bash
# …
```
