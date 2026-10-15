# post_roms3d

Regrid ROMS 3-D history onto fixed z-levels, then CAWO LL0.025 (`ocean3d`).

## Files

| File | Role |
|------|------|
| `post_roms3d_xesmf.py` | `process_roms3d_xesmf(infile, outfile)` |
| `slurm_run_post_roms3d.bash` | Date-array SLURM wrapper |
| `test_zlevs.py` | Ad-hoc z-level smoke test |

## I/O

- **In:** `$CAWO_OUTPUT/fYYYYMMDD/cawo_g2.8.0_his_YYYYMMDD_12_XXXXX.nc`
- **Out:** `$CAWO_POST/ocean3d/fYYYYMMDD/inacawo_hindcast_ocean3d_YYYY-MM-DD_HH:MM:SS.nc`
- **HIS list:** `1 4 7 10 13 16 19 22 25` (3-hourly)
- **Layers:** z = 0, −10, −25, −50, −100, −250, −500, −1000, −2000 m

## Usage

```bash
./run_postprocess.bash --start YYYYMMDD --end YYYYMMDD --stage roms3d
```

Manual:

```bash
cd $WORK_BASE/postprocess/post_roms3d
sbatch slurm_run_post_roms3d.bash
```
