# post_wrf3d

Regrid WRF pressure-level (`wrfplev`) fields to CAWO LL0.025 (`wrf3d`), 3-hourly.

## Files

| File | Role |
|------|------|
| `post_wrf3d_xesmf.py` | `process_wrf3d_xesmf(infile, outfile)` |
| `slurm_run_post_wrf3d.bash` | Date-array SLURM wrapper |

## I/O

- **In:** `$CAWO_OUTPUT/fYYYYMMDD/wrfplev_d01_*`
- **Out:** `$CAWO_POST/wrf3d/fYYYYMMDD/post3d_YYYY-MM-DD_HH:MM:SS.nc`
  (legacy `post3d_` prefix — shared archive uses `inacawo_hindcast_wrf3d_*`)
- Levels: 950, 925, 850, 700, 600, 500 hPa
- Same 3-hourly filter / `SKIP_FIRST_3H_INIT` as wrf2d

## Usage

```bash
./run_postprocess.bash --start YYYYMMDD --end YYYYMMDD --stage wrf3d
```

Manual:

```bash
cd $WORK_BASE/postprocess/post_wrf3d
sbatch slurm_run_post_wrf3d.bash
```
