#!/bin/bash
# Script to populate COAWST run folders with required files
# Robust handling of wildcards and mandatory files

set -euo pipefail
shopt -s nullglob

RUNS_DIR=$CAWO_HINDCAST_RUN
WPS_BASE=$WPS_RUN_DIR
SWAN_BCS="$CAWO_INPUT/swan_bcs"
MODEL_DIR="$MODEL_BASE/cawo_3way_swell_mods_no_ramp_tides"

# === Define date range ===
date_start=19950102
date_end=19950105

# --- helper functions ---

# Copy a single mandatory file
copy_file () {
    local src="$1"
    local dest="$2"
    if [[ ! -e "$src" ]]; then
        echo "ERROR: Missing file $src"
        exit 1
    fi
    cp "$src" "$dest"
}

# Copy one or more files matching patterns (wildcards mandatory)
copy_required () {
    local dest="${@: -1}"   # last argument is destination
    local patterns=("${@:1:$#-1}")  # all arguments except last
    local files=()

    for pat in "${patterns[@]}"; do
        local matches=($pat)   # expand glob
        if [[ ${#matches[@]} -eq 0 ]]; then
            echo "ERROR: No files match pattern $pat"
            exit 1
        fi
        files+=("${matches[@]}")
    done

    cp "${files[@]}" "$dest"
}

# === Main loop ===
cd "$RUNS_DIR" || exit 1

current_date="$date_start"
while [[ "$current_date" -le "$date_end" ]]; do
    run="f${current_date}"

    if [[ -d "$run" ]]; then
        echo ">>> Setting up $run (date $current_date)"
        cd "$run"

        # ---- coawstM binary ----
        copy_file "$MODEL_DIR/coawstM" "coawstM"

        # ---- WPS/real date-specific files ----
        WPS_DIR="$WPS_BASE/era5_${current_date}/real"
        if [[ ! -d "$WPS_DIR" ]]; then
            echo "ERROR: WPS dir not found: $WPS_DIR"
            exit 1
        fi

        # Mandatory wildcards
        copy_required "$WPS_DIR/wrf*" "$WPS_DIR/fip_norm_*" "$WPS_DIR"/*.TBL "$WPS_DIR/ozone*" "$WPS_DIR"/*.dat "$WPS_DIR"/RRTM* .

        # Mandatory single files
        copy_file "$WPS_DIR/icetype_norm.tabl" .
        copy_file "$WPS_DIR/snow_rat_fn.txt" .

        # ---- Static/common files ----
        copy_file "$IN_TEMPLATES/htr_iofields_list.txt" "$CAWO_HINDCAST_RUN/htr_iofields_list.txt"
        copy_file "$IN_TEMPLATES/slurm_run_cawo_3way_hdcst.bash" "$CAWO_HINDCAST_RUN"
        copy_file "$SWAN_STATIC/swan_bathy_v255.bot" "$CAWO_HINDCAST_RUN"
        copy_file "$SWAN_STATIC/swan_coord_v255.grd" "$CAWO_HINDCAST_RUN"
        copy_file "$VARINFO/varinfo.dat" "$CAWO_HINDCAST_RUN"
        copy_file "$GRID_SCRIP/scrip_mar2023.nc" "$CAWO_HINDCAST_RUN"
        copy_file "$IN_TEMPLATES/coupling_cawo.in.template" "$CAWO_HINDCAST_RUN/coupling_cawo.in"

        cd ..
    else
        echo "Skipping $run (not found)"
    fi

    # === Increment date ===
    current_date=$(date -d "$current_date +1 day" +%Y%m%d)
done
