# LO_user

LiveOcean **user** tree for InaCAWO: path config + forcing implementations.
Git-tracked here; LO library code lives in `$HOME/inacawo-deps/LO`.

## Important files

| Path | Role |
|------|------|
| `get_lo_info.py` | Portable `Ldir` paths (`LO`, `LO_USER`, `$CAWO_INPUT/LO_*`) |
| `forcing/ocnA0/` | Atmosphere / river-style ocnA0 forcing |
| `forcing/ocnGcawo/` | GLORYS→ROMS (ocnG) forcing |
| `driver/` | Legacy SLURM drivers (prefer `../get_roms_icbc/`) |
| `extract/`, `pgrid/` | Upstream LO tools (optional / advanced) |

## Usage

Do not call these in isolation for production hindcast — use:

```bash
cd $WORK_BASE/preprocess/get_roms_icbc
sbatch slurm_run_ocnA0_….bash
sbatch slurm_run_ocnGcawo_….bash
```

Those entrypoints import / invoke the forcing code here after `setup_env.bash`.

Nested `README.md` files under `extract/` and `pgrid/` are upstream LiveOcean
docs; paths in them may refer to generic `LO_data` / `LO_output` names (resolved
via `get_lo_info.py` to `$CAWO_INPUT/...`).
