#!/bin/bash
#SBATCH --job-name=post3d_days
#SBATCH --array=0-365%9      # adjust max days and concurrency as needed
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=8
#SBATCH --mem=64G
#SBATCH --time=02:00:00
#SBATCH --partition=HDCAST
#SBATCH --output=log/post3d_%A_%a.out

source ~/.bashrc
source $CONDA_BASE/etc/profile.d/conda.sh
conda activate cawo_post

########################################
# USER INPUT
########################################
START_DATE="1995-01-01"      # date corresponding to array index 0
END_DATE="1995-01-05"        # inclusive; change as needed

HIND_ROOT=$CAWO_OUTPUT
OUT_ROOT="$CAWO_POST/wrf3d"

# ---- Manual flag: skip first 3-hourly file in EACH day? ----
# 0 = do NOT skip (process all 3-hourly files for each day)
# 1 = skip the first 3-hourly file for each day (to avoid overlap)
SKIP_FIRST_3H_INIT=1
########################################

TASK_ID=${SLURM_ARRAY_TASK_ID}

# Compute this task's date: START_DATE + TASK_ID days
RUN_DATE=$(date -d "${START_DATE} + ${TASK_ID} day" +%Y-%m-%d)

# If we have gone past END_DATE, this task has nothing to do
if [[ "$RUN_DATE" > "$END_DATE" ]]; then
    echo "TASK_ID $TASK_ID -> RUN_DATE $RUN_DATE > END_DATE $END_DATE. Nothing to do."
    exit 0
fi

echo "TASK_ID $TASK_ID processing date $RUN_DATE"

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

# Local flag for this day: start from SKIP_FIRST_3H_INIT
SKIP_FIRST_3H=${SKIP_FIRST_3H_INIT}

shopt -s nullglob
for INFILE in "${IN_DAY_DIR}"/wrfplev_d01_*; do
    BASENAME=$(basename "$INFILE")         # wrfplev_d01_1995-01-01_12:00:00
    TIMEPART=${BASENAME#wrfplev_d01_}      # 1995-01-01_12:00:00

    # Extract hour: YYYY-MM-DD_HH:MM:SS -> HH at pos 12–13 (0-based index 11)
    HOUR=${TIMEPART:11:2}

    # Keep only 3-hourly files (00,03,06,...,21)
    if (( 10#$HOUR % 3 != 0 )); then
        continue
    fi

    # Optionally skip the first 3-hourly file in this day
    if (( SKIP_FIRST_3H == 1 )); then
        echo "Skipping first 3-hourly file for ${RUN_DATE}: ${INFILE}"
        SKIP_FIRST_3H=0
        continue
    fi

    OUTFILE="${OUT_DAY_DIR}/post3d_${TIMEPART}.nc"

    echo "Processing $INFILE -> $OUTFILE"

    python - << EOF
from post_wrf3d_xesmf import process_wrf3d_xesmf

infile = "${INFILE}"
outfile = "${OUTFILE}"

process_wrf3d_xesmf(infile, outfile)
EOF

    STATUS=\$?
    if [ \$STATUS -ne 0 ]; then
        echo "ERROR: process_wrf3d_xesmf failed for ${INFILE} with status \${STATUS}"
        exit \$STATUS
    fi
done

echo "Finished all 3-hourly files for ${RUN_DATE}"

