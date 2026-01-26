#!/bin/bash
#SBATCH --job-name=postR3d_days
#SBATCH --array=0-10%9      # adjust range and concurrency as needed
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=8
#SBATCH --mem=240G
#SBATCH --time=03:00:00
#SBATCH --partition=HDCAST
#SBATCH --output=LOG/post_roms3d_%A_%a.out
#SBATCH --error=LOG/post_roms3d_%A_%a.err

source ~/.bashrc
source ~/opt/miniforge3/bin/activate
conda activate cawo_post

########################################
# USER INPUT
########################################
START_DATE="1995-01-01"      # date corresponding to array index 0
END_DATE="1995-01-05"        # inclusive; change as needed

HIND_ROOT="/scratch/cawohdcst_ft2/data/cawo_hindcast_outputs"
OUT_ROOT="/scratch/cawohdcst_ft2/data/postprocessed/ocean3d"

# Directory where post_roms3d_xesmf.py lives
POSTPROC_DIR="/home/cawohdcst_ft2/postprocess"

# ROMS his numbers to process
# 1 occurs only on f19950101; others (4,7,10,...) appear on all days
HIS_LIST="1 4 7 10 13 16 19 22 25"
########################################

TASK_ID=${SLURM_ARRAY_TASK_ID}

# Compute this task's date: START_DATE + TASK_ID days
RUN_DATE=$(date -d "${START_DATE} + ${TASK_ID} day" +%Y-%m-%d)

# Stop tasks that are past END_DATE
if [[ "$RUN_DATE" > "$END_DATE" ]]; then
    echo "TASK_ID $TASK_ID -> RUN_DATE $RUN_DATE > END_DATE $END_DATE. Nothing to do."
    exit 0
fi

echo "TASK_ID ${TASK_ID} processing date ${RUN_DATE}"

# Day folder name: fYYYYMMDD
DAYTAG=$(echo "$RUN_DATE" | tr -d '-')   # 1995-01-01 -> 19950101
DAYDIR="f${DAYTAG}"

IN_DAY_DIR="${HIND_ROOT}/${DAYDIR}"
OUT_DAY_DIR="${OUT_ROOT}/${DAYDIR}"

if [ ! -d "${IN_DAY_DIR}" ]; then
    echo "Input directory ${IN_DAY_DIR} does not exist, skipping."
    exit 0
fi

mkdir -p "${OUT_DAY_DIR}"

echo "Input dir:  ${IN_DAY_DIR}"
echo "Output dir: ${OUT_DAY_DIR}"

shopt -s nullglob

# Loop only over the his numbers we care about
for HIS in ${HIS_LIST}; do
    HIS_STR=$(printf "%05d" "${HIS}")   # 1 -> 00001, 4 -> 00004, etc.
    INFILE="${IN_DAY_DIR}/cawo_g2.8.0_his_${DAYTAG}_12_${HIS_STR}.nc"

    if [ ! -f "${INFILE}" ]; then
        echo "File not found for HIS=${HIS}: ${INFILE} (skipping)"
        continue
    fi

    echo "Processing ROMS file: ${INFILE}"

    python - << EOF
import sys
import xarray as xr
import pandas as pd

# Ensure we can import post_roms3d_xesmf from POSTPROC_DIR
postproc_dir = "${POSTPROC_DIR}"
if postproc_dir not in sys.path:
    sys.path.append(postproc_dir)

from post_roms3d_xesmf import process_roms3d_xesmf

infile = "${INFILE}"
out_dir = "${OUT_DAY_DIR}"

# Open ROMS file to get its actual time
ds = xr.open_dataset(infile)
if "ocean_time" not in ds:
    print(f"[WARN] 'ocean_time' not found in {infile}, skipping.")
    raise SystemExit(0)

t = pd.to_datetime(ds["ocean_time"].isel(ocean_time=0).values)
time_str = t.strftime("%Y-%m-%d_%H:%M:%S")
hour = t.hour

print(f"  ocean_time = {time_str} (hour={hour:02d})")

# Build output file name from actual time
outfile = f"{out_dir}/inacawo_hindcast_ocean3d_{time_str}.nc"

print(f"  -> writing {outfile}")
process_roms3d_xesmf(infile, outfile)
EOF

    STATUS=$?
    if [ $STATUS -ne 0 ]; then
        echo "Python returned status ${STATUS} for ${INFILE}"
        # If you want the whole job to stop on first real error, uncomment:
        # exit $STATUS
    fi
done

echo "Finished selected ROMS 3D files for ${RUN_DATE}"
