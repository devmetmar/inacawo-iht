# post_wrf2d

Regrid WRF hourly surface (`wrfhtr`) fields to CAWO LL0.025 (`wrf2d`), 3-hourly.

## Files

| File | Role |
|------|------|
| `post_wrf2d_xesmf.py` | `process_wrf2d_xesmf(infile, outfile)` |
| `slurm_run_post_wrf2d.bash` | Date-array SLURM wrapper |

## I/O

- **In:** `$CAWO_OUTPUT/fYYYYMMDD/wrfhtr_d01_*`
- **Out:** `$CAWO_POST/wrf2d/fYYYYMMDD/inacawo_hindcast_wrf2d_YYYY-MM-DD_HH:MM:SS.nc`
- Skips non–3-hourly hours; `SKIP_FIRST_3H_INIT=1` drops the first 3-hourly file each day (overlap).

## Usage

```bash
./run_postprocess.bash --start YYYYMMDD --end YYYYMMDD --stage wrf2d
```

Manual:

```bash
cd $WORK_BASE/postprocess/post_wrf2d
sbatch slurm_run_post_wrf2d.bash
```
