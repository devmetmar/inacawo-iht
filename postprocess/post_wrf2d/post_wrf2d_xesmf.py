#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import xarray as xr
import numpy as np
import pandas as pd
import xesmf as xe


# ---------------------------------------------------------------------
# Helper to decode WRF Times
# ---------------------------------------------------------------------
def decode_wrftime(rt):
    """Robustly decode WRF Times into a string."""
    # single bytes
    if isinstance(rt, bytes):
        return rt.decode("utf-8")

    # numpy arrays (bytes or unicode)
    if isinstance(rt, np.ndarray):
        if rt.dtype.kind == "S":  # bytes
            return b"".join(rt.flatten()).decode("utf-8")
        if rt.dtype.kind == "U":  # unicode
            return "".join(rt.flatten())

    # fallback
    return str(rt)


# ---------------------------------------------------------------------
# Main processing function for 2D WRF hourly files
# ---------------------------------------------------------------------
def process_wrf2d_xesmf(
    infile,
    outfile,
    # CAWO_LL025 target grid (same as 3D script)
    lon_min=90.0,
    lon_max=145.0,
    lat_min=-15.0,
    lat_max=15.0,
    dlon=0.025,
    dlat=0.025,
):
    """Post-process WRF 2D surface/hourly file into IOAPI-style 2D file
    on the CAWO lat/lon grid using xESMF regridding.

    Output variables (if present in infile):
        SEA_SFC_TEMP   (SST)
        RELHUM_2M      (RH2)
        U_EASTWARD_10M (UX10)
        V_NORTHWARD_10M(VX10)
        GUST_SPEED_10M (GSPD10)
        MLCAPE         (MLCAPE)
        ACCUM_PCP_TOT  (PCPTOTAL_CUM)
        MEAN_SEALEV_PRS(SLPRS)
        VISIBILITY     (VISIBILITY)
        TOTFLSHRT_PHR   (TOTFLSHRT_PHR)
    """

    # ------------------------------------------------------------------
    # Open dataset
    # ------------------------------------------------------------------
    ds = xr.open_dataset(infile)

    # ------------------------------------------------------------------
    # Source (WRF) grid: XLAT / XLONG at time 0
    # ------------------------------------------------------------------
    src_lat = ds["XLAT"].isel(Time=0)   # (south_north, west_east)
    src_lon = ds["XLONG"].isel(Time=0)

    # ------------------------------------------------------------------
    # Target (CAWO) grid: regular lat/lon grid
    # ------------------------------------------------------------------
    lon_1d = np.arange(lon_min, lon_max + 0.5 * dlon, dlon)
    lat_1d = np.arange(lat_min, lat_max + 0.5 * dlat, dlat)

    ncols = lon_1d.size
    nrows = lat_1d.size

    tgt_lon2d, tgt_lat2d = np.meshgrid(lon_1d, lat_1d)

    ROW = lat_1d.astype("float64")
    COL = lon_1d.astype("float64")

    # ------------------------------------------------------------------
    # Time handling: decode WRF Times and convert to seconds since epoch
    # ------------------------------------------------------------------
    raw_time = ds["Times"].isel(Time=0).values
    raw_time_str = decode_wrftime(raw_time)     # "YYYY-mm-dd_HH:MM:SS"
    raw_time_str = raw_time_str.replace("_", " ")
    ds_time = pd.to_datetime(raw_time_str)

    # IOAPI TSTEP (seconds since 1970-01-01)
    TSTEP_vals = np.array(
        [(np.datetime64(ds_time) - np.datetime64("1970-01-01T00:00:00")) /
         np.timedelta64(1, "s")],
        dtype="float64",
    )

    # ------------------------------------------------------------------
    # Build xESMF regridder: WRF native → CAWO_LL025
    # ------------------------------------------------------------------
    grid_src = {"lon": src_lon.values, "lat": src_lat.values}
    grid_tgt = {"lon": tgt_lon2d, "lat": tgt_lat2d}

    regridder = xe.Regridder(
        grid_src,
        grid_tgt,
        method="bilinear",
        reuse_weights=False,
    )

    # ------------------------------------------------------------------
    # Mapping WRF -> IOAPI variable names
    # ------------------------------------------------------------------
    rename_map = {
        "SST": "SEA_SFC_TEMP",
        "RH2": "RELHUM_2M",
        "UX10": "U_EASTWARD_10M",
        "VX10": "V_NORTHWARD_10M",
        "GSPD10": "GUST_SPEED_10M",
        "MLCAPE": "MLCAPE",
        "PCPTOTAL_CUM": "ACCUM_PCP_TOT",
        "SLPRS": "MEAN_SEALEV_PRS",
        "VISIBILITY": "VISIBILITY_IN_AIR",
        "TOTFLSHRT_PHR": "TOTFLSHRT_PHR",
        "CFRACL": "LOW_CLOUD_FRACTION",
        "CFRACM": "MID_CLOUD_FRACTION",
        "CFRACH": "HIGH_CLOUD_FRACTION",
    }

    # ------------------------------------------------------------------
    # Helper to regrid a 2D surface field
    # ------------------------------------------------------------------
    def regrid_2d_var(varname):
        """Regrid a 2D surface variable to CAWO grid."""
        if varname not in ds:
            return None

        src = ds[varname].isel(Time=0)  # (south_north, west_east)
        src_vals = src.values

        out2d = regridder(src_vals)     # (nrows, ncols)
        out4d = out2d[np.newaxis, np.newaxis, ...]   # (1, 1, ROW, COL)
        return out4d

    # ------------------------------------------------------------------
    # Create core variables
    # ------------------------------------------------------------------
    out_vars = {}
    for wrf_var, ioapi_var in rename_map.items():
        vals = regrid_2d_var(wrf_var)
        if vals is not None:
            out_vars[ioapi_var] = xr.DataArray(
                vals,
                dims=("TSTEP", "LAY", "ROW", "COL"),
                name=ioapi_var,
            )

    # Convert VISIBILITY from km (WRF native) to m
    if "VISIBILITY_IN_AIR" in out_vars:
        out_vars["VISIBILITY_IN_AIR"] = out_vars["VISIBILITY_IN_AIR"] * 1000.0

    if not out_vars:
        raise RuntimeError(
            "No output variables were created. "
            "Check that expected WRF variables exist in the input file."
        )

    # ------------------------------------------------------------------
    # Build Dataset and coordinates
    # ------------------------------------------------------------------
    ds_out = xr.Dataset(out_vars)

    ds_out = ds_out.assign_coords(
        TSTEP=("TSTEP", TSTEP_vals),
        ROW=("ROW", ROW),
        COL=("COL", COL),
        LAY=("LAY", [0.0]),
    )

    # 1D lat/lon variables for CF-ish metadata
    ds_out["lat"] = xr.DataArray(
        ROW.astype("float32"),
        dims=("ROW",),
        attrs=dict(
            axis="Y",
            long_name="latitude",
            standard_name="latitude",
            units="degrees_north",
            grid_mapping="geographic",
        ),
    )
    ds_out["lon"] = xr.DataArray(
        COL.astype("float32"),
        dims=("COL",),
        attrs=dict(
            axis="X",
            long_name="longitude",
            standard_name="longitude",
            units="degrees_east",
            grid_mapping="geographic",
        ),
    )

    # ROW/COL coordinate attributes (projection_x/y)
    ds_out["ROW"].attrs = dict(
        axis="Y",
        long_name="latitude",
        standard_name="projection_y_coordinate",
        units="degrees_north",
        grid_mapping="geographic",
    )
    ds_out["COL"].attrs = dict(
        axis="X",
        long_name="longitude",
        standard_name="projection_x_coordinate",
        units="degrees_east",
        grid_mapping="geographic",
    )

    # LAY coordinate (surface only, no physical pressure attached)
    ds_out["LAY"].attrs = dict(
        axis="Z",
        long_name="layer",
        units="1",
    )

    # grid_mapping variable
    ds_out["geographic"] = xr.DataArray(
        np.array(" ", dtype="S1"),
        attrs=dict(
            grid_mapping_name="latitude_longitude",
        ),
    )

    # ------------------------------------------------------------------
    # Variable attributes (IOAPI-style, matching forecast files)
    # ------------------------------------------------------------------
    def set_var_attrs(name, attrs):
        if name in ds_out:
            ds_out[name].attrs.update(attrs)

    set_var_attrs(
        "SEA_SFC_TEMP",
        dict(
            long_name="SEA_SFC_TEMP",
            standard_name="sea_surface_temperature",
            units="K",
            _FillValue=np.float32(-9.999e36),
            var_desc="SEA SURFACE TEMPERATURE",
        ),
    )
    set_var_attrs(
        "RELHUM_2M",
        dict(
            long_name="RELHUM_2M",
            standard_name="relative_humidity",
            units="%",
            _FillValue=np.float32(-9.999e36),
            var_desc="2 meter relative humidity",
        ),
    )
    set_var_attrs(
        "U_EASTWARD_10M",
        dict(
            long_name="U_EASTWARD_10M",
            standard_name="eastward_wind",
            units="m s-1",
            _FillValue=np.float32(-9.999e36),
            var_desc="Earth-relative UWIND at 10-meters",
        ),
    )
    set_var_attrs(
        "V_NORTHWARD_10M",
        dict(
            long_name="V_NORTHWARD_10M",
            standard_name="northward_wind",
            units="m s-1",
            _FillValue=np.float32(-9.999e36),
            var_desc="Earth-relative VWIND at 10-meters",
        ),
    )
    set_var_attrs(
        "GUST_SPEED_10M",
        dict(
            long_name="GUST_SPEED_10M",
            standard_name="GUST_SPEED_10M",
            units="m s-1",
            _FillValue=np.float32(-9.999e36),
            var_desc="Estimated max gust speed 10-meters above ground",
        ),
    )
    set_var_attrs(
        "ACCUM_PCP_TOT",
        dict(
            long_name="ACCUM_PCP_TOT",
            standard_name="precipitation_amount",
            units="kg m-2",
            _FillValue=np.float32(-9.999e36),
            var_desc="accumulated total (conv + non-conv) PCP (all types)",
        ),
    )
    set_var_attrs(
        "MEAN_SEALEV_PRS",
        dict(
            long_name="MEAN_SEALEV_PRS",
            standard_name="air_pressure_at_mean_sea_level",
            units="hPa",
            _FillValue=np.float32(-9.999e36),
            var_desc="WRF Mean-sea-level pressure",
        ),
    )
    set_var_attrs(
        "MLCAPE",
        dict(
            long_name="MLCAPE",
            standard_name="atmosphere_convective_available_potential_energy",
            units="J kg-1",
            _FillValue=np.float32(-9.999e36),
            var_desc="Mixed-layer CAPE",
        ),
    )
    set_var_attrs(
        "VISIBILITY_IN_AIR",
        dict(
            long_name="VISIBILITY",
            standard_name="visibility_in_air",
            units="m",
            _FillValue=np.float32(-9.999e36),
            var_desc="Near-surface horizontal visibility",
        ),
    )
    set_var_attrs(
        "TOTFLSHRT_PHR",
        dict(
            long_name="TOTLSHRT_PHR",
            standard_name="total_lightning_flash_rate_per_hour",
            units="Flshs/hr",
            _FillValue=np.float32(-9.999e36),
            var_desc="Total lightning flash rate per hour",
        ),
    )
    set_var_attrs(
        "LOW_CLOUD_FRACTION",
        dict(
            long_name="LOW_CLOUD_FRACTION",
            standard_name="low_cloud_fraction",
            units="none",
            _FillValue=np.float32(-9.999e36),
            var_desc="Low cloud fraction",
        ),
    )
    set_var_attrs(
        "MID_CLOUD_FRACTION",
        dict(
            long_name="MID_CLOUD_FRACTION",
            standard_name="mid_cloud_fraction",
            units="none",
            _FillValue=np.float32(-9.999e36),
            var_desc="Mid cloud fraction",
        ),
    )
    set_var_attrs(
        "HIGH_CLOUD_FRACTION",
        dict(
            long_name="HIGH_CLOUD_FRACTION",
            standard_name="high_cloud_fraction",
            units="none",
            _FillValue=np.float32(-9.999e36),
            var_desc="High cloud fraction",
        ),
    )


    # Ensure all core vars are float32
    for v in out_vars:
        ds_out[v] = ds_out[v].astype("float32")
        if "_FillValue" not in ds_out[v].attrs:
            ds_out[v].attrs["_FillValue"] = np.float32(-9.999e36)

    # ------------------------------------------------------------------
    # TFLAG and RUNTIME
    # ------------------------------------------------------------------
    var_list = list(out_vars.keys())
    nvar = len(var_list)

    YYYY = ds_time.year
    DDD = ds_time.dayofyear
    HH = ds_time.hour
    MM = ds_time.minute
    SS = ds_time.second

    DATEFLAG = YYYY * 1000 + DDD
    TIMEFLAG = HH * 10000 + MM * 100 + SS

    TFLAG = np.zeros((1, nvar, 2), dtype="int32")
    TFLAG[:, :, 0] = DATEFLAG
    TFLAG[:, :, 1] = TIMEFLAG

    ds_out["TFLAG"] = xr.DataArray(
        TFLAG,
        dims=("TSTEP", "VAR", "DATE-TIME"),
        attrs=dict(
            units="<YYYYDDD,HHMMSS>",
            long_name="TFLAG           ",
            var_desc="Timestep-valid flags:  (1) YYYYDDD or (2) HHMMSS                                ",
        ),
    )

    # TSTEP variable attrs
    ds_out["TSTEP"].attrs = dict(
        axis="T",
        long_name="time",
        standard_name="time",
        units="seconds since 1970-1-1 0:0:0",
    )

    # RUNTIME: for hindcast, equal to valid time
    ds_out["RUNTIME"] = xr.DataArray(
        TSTEP_vals.copy(),
        dims=("TSTEP",),
        attrs=dict(
            axis="T",
            long_name="forecast reference time aka run time or analysis time in cf convention",
            standard_name="forecast_reference_time",
            units="seconds since 1970-1-1 0:0:0",
        ),
    )

    # ------------------------------------------------------------------
    # Global IOAPI-like attributes
    # ------------------------------------------------------------------
    nrows = ds_out.dims["ROW"]
    ncols = ds_out.dims["COL"]
    nlays = ds_out.dims["LAY"]
    nvars = nvar

    # Grid resolution and origin
    if ncols > 1:
        xcell = float(COL[1] - COL[0])
    else:
        xcell = dlon
    if nrows > 1:
        ycell = float(ROW[1] - ROW[0])
    else:
        ycell = dlat

    xorig = float(COL[0] - 0.5 * xcell)
    yorig = float(ROW[0] - 0.5 * ycell)

    # IOAPI date/time ints
    cdate = YYYY * 1000 + DDD
    ctime = HH * 10000 + MM * 100 + SS

    # VAR-LIST: 16-char padded names concatenated
    var_list_padded = "".join([f"{v:16s}" for v in var_list])

    ds_out.attrs.update(
        dict(
            IOAPI_VERSION="ioapi-3.2: $Id: init3.F90 200 2021-05-10 14:06:20Z coats $                      ",
            EXEC_ID="WRF2D-hindcast                                                            ",
            FTYPE=1,
            CDATE=cdate,
            CTIME=ctime,
            WDATE=cdate,
            WTIME=ctime,
            SDATE=cdate,
            STIME=0,
            TSTEP=10000,
            NTHIK=1,
            NCOLS=ncols,
            NROWS=nrows,
            NLAYS=nlays,
            NVARS=nvars,
            GDTYP=1,
            P_ALP=0.0,
            P_BET=0.0,
            P_GAM=0.0,
            XCENT=0.0,
            YCENT=0.0,
            XORIG=xorig,
            YORIG=yorig,
            XCELL=xcell,
            YCELL=ycell,
            VGTYP=-9999,
            VGTOP=0.0,
            VGLVLS=(0.0, 1.0),
            GDNAM="CAWO_LL025      ",
            UPNAM="M3EDHDR         ",
            **{"VAR-LIST": var_list_padded},
            FILEDESC="CAWO WRF 2D hindcast, selected vars on 0.025 degree lat/lon grid          ",
            HISTORY="",
            Conventions="CF-1.0",
        )
    )

    # ------------------------------------------------------------------
    # Write NetCDF with TSTEP unlimited
    # ------------------------------------------------------------------
    ds_out.to_netcdf(
        outfile,
        format="NETCDF4",
        unlimited_dims=["TSTEP"],
    )


# Example usage:
# process_wrf2d_xesmf(
#     "wrfhtr_d01_1995-01-02_07:00:00",
#     "post2d_1995-01-02_07.nc",
# )
