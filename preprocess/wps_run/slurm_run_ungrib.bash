#!/bin/bash
#SBATCH --partition=HDCAST
#SBATCH --job-name=run_ungrib_loop
#SBATCH --ntasks=1
#SBATCH --time=200:00:00
#SBATCH --output=log/run_ungrib_loop_%j.log


# InaCAWO portable env + hindcast conda
if [[ -f "${HOME}/inacawo-iht/setup_env.bash" ]]; then
  # shellcheck disable=SC1091
  source "${HOME}/inacawo-iht/setup_env.bash"
elif [[ -n "${WORK_BASE:-}" && -f "${WORK_BASE}/setup_env.bash" ]]; then
  # shellcheck disable=SC1091
  source "${WORK_BASE}/setup_env.bash"
else
  echo "ERROR: missing setup_env.bash" >&2
  exit 1
fi

source $COAWST_ENV

# Loop range (format: YYYYMMDD)
START_DATE=19950106
END_DATE=19950106

# Base directories
STATIC_WPS_DIR=$WPS_STATIC_DIR
ERA5_BASE_DIR=$ERA5_BASE_DIR
UNGRIB_BASE_DIR=$WPS_RUN_DIR

# Function to format date for sed
format_date_parts() {
    local ymd=$1
    YYYY=${ymd:0:4}
    MM=${ymd:4:2}
    DD=${ymd:6:2}
}

# Loop over each day
current_date=$START_DATE
while [[ "$current_date" -le "$END_DATE" ]]; do

    next_date=$(date -d "$current_date +1 day" +%Y%m%d)
    
    echo "Processing $current_date to $next_date"

    run_dir=$UNGRIB_BASE_DIR/era5_$current_date/ungrib/
    mkdir -p "$run_dir"
    cd "$run_dir" || exit 1

    #################
    # Pressure-level
    #################

    cp $STATIC_WPS_DIR/ungrib/ungrib.exe .
    cp $STATIC_WPS_DIR/ungrib/namelist.wps.template_pl ./namelist.wps

    format_date_parts "$current_date"
    BYYYY=$YYYY; BMM=$MM; BDD=$DD; CYCLE=12

    format_date_parts "$next_date"
    EYYYY=$YYYY; EMM=$MM; EDD=$DD; CYCLE2=12

    # Replace in namelist
    sed -i "s/YYYY1/$BYYYY/g" namelist.wps
    sed -i "s/YYYY2/$EYYYY/g" namelist.wps
    sed -i "s/MM1/$BMM/g" namelist.wps
    sed -i "s/MM2/$EMM/g" namelist.wps
    sed -i "s/DD1/$BDD/g" namelist.wps
    sed -i "s/DD2/$EDD/g" namelist.wps
    sed -i "s/CY1/$CYCLE/g" namelist.wps
    sed -i "s/CY2/$CYCLE2/g" namelist.wps

    cp $STATIC_WPS_DIR/ungrib/link_grib.csh .
    ./link_grib.csh $ERA5_BASE_DIR/era5_$current_date/era5_pl_*.grib

    cp $STATIC_WPS_DIR/ungrib/Variable_Tables/Vtable.ECMWF ./Vtable
    ./ungrib.exe

    #################
    # Surface-level
    #################

    rm -f GRIBFILE.*

    cp $STATIC_WPS_DIR/ungrib/namelist.wps.template_sfc ./namelist.wps

    # Repeat the replacements for surface
    sed -i "s/YYYY1/$BYYYY/g" namelist.wps
    sed -i "s/YYYY2/$EYYYY/g" namelist.wps
    sed -i "s/MM1/$BMM/g" namelist.wps
    sed -i "s/MM2/$EMM/g" namelist.wps
    sed -i "s/DD1/$BDD/g" namelist.wps
    sed -i "s/DD2/$EDD/g" namelist.wps
    sed -i "s/CY1/$CYCLE/g" namelist.wps
    sed -i "s/CY2/$CYCLE2/g" namelist.wps

    ./link_grib.csh $ERA5_BASE_DIR/era5_$current_date/era5_surface_*.grib
    cp $STATIC_WPS_DIR/ungrib/Variable_Tables/Vtable.ECMWF_no_sst ./Vtable
    ./ungrib.exe

    # Link FILE_SFC* to FILE:* format
    for f in FILE_SFC*; do
        [[ -f "$f" ]] || continue
        str2=$(echo "$f" | cut -d ":" -f2)
        ln -sf "$f" FILE:"$str2"
    done

    rm -f TAVGSFC
    $STATIC_WPS_DIR/util/avg_tsfc.exe

    # Advance to next day
    current_date=$(date -d "$current_date +1 day" +%Y%m%d)

done
