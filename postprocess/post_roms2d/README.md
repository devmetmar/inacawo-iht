# post_roms2d

Regrid ROMS/SWAN surface history to CAWO LL0.025 (`ocean2d`).

## Files

| File | Role |
|------|------|
| `post_roms2d_xesmf.py` | `process_ocean2d_xesmf(infile, outfile)` |
| `slurm_run_post_roms2d.bash` | Date-array SLURM wrapper |

## I/O

- **In:** `$CAWO_OUTPUT/fYYYYMMDD/cawo_g2.8.0_his_YYYYMMDD_12_XXXXX.nc`
- **Out:** `$CAWO_POST/ocean2d/fYYYYMMDD/inacawo_hindcast_ocean2d_YYYY-MM-DD_HH:MM:SS.nc`
- **HIS list:** `1 4 7 10 13 16 19 22 25` (3-hourly)

## Usage

Preferred (from repo root or `postprocess/`):

```bash
./run_postprocess.bash --start YYYYMMDD --end YYYYMMDD --stage roms2d
```

Manual:

```bash
cd $WORK_BASE/postprocess/post_roms2d
# optional: export IHT_START_DATE_ISO=… IHT_END_DATE_ISO=…
sbatch slurm_run_post_roms2d.bash
```
