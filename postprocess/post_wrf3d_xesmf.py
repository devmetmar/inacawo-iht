#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import xarray as xr
import numpy as np
import pandas as pd
import xesmf as xe


def decode_wrftime(rt):
    """Robustly decode WRF Times into a string."""
    if isinstance(rt, bytes):
        return rt.decode("utf-8")
    if isinstance(rt, np.ndarray):
        if rt.dtype.kind == "S":  # bytes
            return b"".join(rt.flatten()).decode("utf-8")
        if rt.dtype.kind == "U":  # unicode
            return "".join(rt.flatten())
    return str(rt)


def process_wrf3d_xesmf(
    infile,
    outfile,
    target_pressures_hpa=(950, 925, 850, 700, 600, 500),
    lon_min=90.0,
    lon_max=145.0,
    lat_min=-15.0,
    lat_max=15.0,
    dlon=0.025,
    dlat=0.025,
):
    """
    Post-process WRF 3D pressure-level file into IOAPI-style 3D file
    on the CAWO regular lat/lon grid using xESMF regridding.

    Output variables (if present in infile):
        DEWPT_TMP  (from TD_PL)
        RELHUM     (from RH_PL)
        U_WIND     (from U_PL)
        V_WIND     (from V_PL)
        TEMP_AIR   (from T_PL)
    """

    ds = xr.open_dataset(infile)

    # -------------------------------------------------------------
    # Source grid: WRF lat/lon at time 0
    # -------------------------------------------------------------
    src_lat = ds["XLAT"].isel(Time=0)   # (south_north, west_east)
    src_lon = ds["XLONG"].isel(Time=0)

    # -------------------------------------------------------------
    # Target grid: CAWO regular lat/lon grid
    # -------------------------------------------------------------
    lon_1d = np.arange(lon_min, lon_max + 0.5 * dlon, dlon)
    lat_1d = np.arange(lat_min, lat_max + 0.5 * dlat, dlat)
    ncols = lon_1d.size
    nrows = lat_1d.size

    tgt_lon2d, tgt_lat2d = np.meshgrid(lon_1d, lat_1d)

    ROW = lat_1d.astype("float64")
    COL = lon_1d.astype("float64")

    # -------------------------------------------------------------
    # Time handling
    # -------------------------------------------------------------
    raw_time = ds["Times"].isel(Time=0).values
    raw_time_str = decode_wrftime(raw_time).replace("_", " ")
    ds_time = pd.to_datetime(raw_time_str)

    TSTEP_vals = np.array(
        [(np.datetime64(ds_time) - np.datetime64("1970-01-01T00:00:00")) /
         np.timedelta64(1, "s")],
        dtype="float64",
    )

    # -------------------------------------------------------------
    # Pressure levels selection
    # -------------------------------------------------------------
    # P_PL(Time, num_press_levels_stag) in Pa
    p_pl = ds["P_PL"].isel(Time=0).values
    target_pressures_pa = np.array(target_pressures_hpa, dtype="float64") * 100.0

    idx_levels = []
    sel_pressures = []
    for p_tgt in target_pressures_pa:
        idx = int(np.argmin(np.abs(p_pl - p_tgt)))
        idx_levels.append(idx)
        sel_pressures.append(p_pl[idx])
    idx_levels = np.array(idx_levels, dtype=int)
    sel_pressures = np.array(sel_pressures, dtype="float64")
    nlay = len(idx_levels)

    # -------------------------------------------------------------
    # xESMF regridder: WRF native -> CAWO grid
    # -------------------------------------------------------------
    grid_src = {"lon": src_lon.values, "lat": src_lat.values}
    grid_tgt = {"lon": tgt_lon2d, "lat": tgt_lat2d}

    regridder = xe.Regridder(
        grid_src,
        grid_tgt,
        method="bilinear",
        reuse_weights=False,
    )

    # -------------------------------------------------------------
    # Helper to regrid 3D pressure-level variables
    # -------------------------------------------------------------
    def regrid_plev_var(varname):
        """
        Regrid a pressure-level variable:
        input dims: (Time, num_press_levels_stag, south_north, west_east)
        output dims: (TSTEP=1, LAY=nlay, ROW=nrows, COL=ncols)
        """
        if varname not in ds:
            return None

        src = ds[varname].isel(Time=0)  # (num_press_levels_stag, south_north, west_east)
        src_vals = src.values

        out_vals = np.empty((nlay, nrows, ncols), dtype="float64")

        for k, idx in enumerate(idx_levels):
            field2d = src_vals[idx, :, :]
            out_vals[k, :, :] = regridder(field2d)

        out_vals = out_vals[np.newaxis, ...]  # (TSTEP, LAY, ROW, COL)
        return out_vals

    # -------------------------------------------------------------
    # Create output variables
    # -------------------------------------------------------------
    out_vars = {}

    vals = regrid_plev_var("TD_PL")
    if vals is not None:
        out_vars["DEWPT_TMP"] = xr.DataArray(
            vals, dims=("TSTEP", "LAY", "ROW", "COL"), name="DEWPT_TMP"
        )

    vals = regrid_plev_var("RH_PL")
    if vals is not None:
        out_vars["RELHUM"] = xr.DataArray(
            vals, dims=("TSTEP", "LAY", "ROW", "COL"), name="RELHUM"
        )

    vals = regrid_plev_var("U_PL")
    if vals is not None:
        out_vars["U_WIND"] = xr.DataArray(
            vals, dims=("TSTEP", "LAY", "ROW", "COL"), name="U_WIND"
        )

    vals = regrid_plev_var("V_PL")
    if vals is not None:
        out_vars["V_WIND"] = xr.DataArray(
            vals, dims=("TSTEP", "LAY", "ROW", "COL"), name="V_WIND"
        )

    vals = regrid_plev_var("T_PL")
    if vals is not None:
        out_vars["TEMP_AIR"] = xr.DataArray(
            vals, dims=("TSTEP", "LAY", "ROW", "COL"), name="TEMP_AIR"
        )

    if not out_vars:
        raise RuntimeError(
            "No output variables created. Check TD_PL, RH_PL, U_PL, V_PL, T_PL in input file."
        )

    # -------------------------------------------------------------
    # Build Dataset and coordinates (no _FillValue on coords)
    # -------------------------------------------------------------
    ds_out = xr.Dataset(out_vars)

    ds_out = ds_out.assign_coords(
        TSTEP=("TSTEP", TSTEP_vals.astype("float64")),
        ROW=("ROW", ROW),
        COL=("COL", COL),
        LAY=("LAY", sel_pressures.astype("float32")),
    )

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

    ds_out["LAY"].attrs = dict(
        axis="Z",
        standard_name="air_pressure",
        units="Pa",
    )

    ds_out["geographic"] = xr.DataArray(
        np.array(" ", dtype="S1"),
        attrs=dict(grid_mapping_name="latitude_longitude"),
    )

    # -------------------------------------------------------------
    # Variable attributes and FillValue for data variables
    # -------------------------------------------------------------
    def set_var_attrs(name, attrs):
        if name in ds_out:
            ds_out[name] = ds_out[name].astype("float32")
            ds_out[name].attrs.update(attrs)
            ds_out[name].attrs["_FillValue"] = np.float32(-9.999e36)

    set_var_attrs(
        "DEWPT_TMP",
        dict(
            long_name="DEWPT_TMP",
            standard_name="dew_point_temperature",
            units="K",
            var_desc="Pressure level data, Dew point temperature",
        ),
    )
    set_var_attrs(
        "RELHUM",
        dict(
            long_name="RELHUM",
            standard_name="relative_humidity",
            units="%",
            var_desc="Pressure level data, Relative humidity",
        ),
    )
    set_var_attrs(
        "U_WIND",
        dict(
            long_name="U_WIND",
            standard_name="eastward_wind",
            units="m s-1",
            var_desc="Pressure level data, U wind",
        ),
    )
    set_var_attrs(
        "V_WIND",
        dict(
            long_name="V_WIND",
            standard_name="northward_wind",
            units="m s-1",
            var_desc="Pressure level data, V wind",
        ),
    )
    set_var_attrs(
        "TEMP_AIR",
        dict(
            long_name="TEMP_AIR",
            standard_name="air_temperature",
            units="K",
            var_desc="Pressure level data, Temperature",
        ),
    )

    # -------------------------------------------------------------
    # TFLAG and RUNTIME
    # -------------------------------------------------------------
    var_list = list(out_vars.keys())
    nvar = len(var_list)

    YYYY = int(ds_time.year)
    DDD = int(ds_time.dayofyear)
    HH = int(ds_time.hour)
    MM = int(ds_time.minute)
    SS = int(ds_time.second)

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
            var_desc=(
                "Timestep-valid flags:  (1) YYYYDDD or (2) HHMMSS                                "
            ),
        ),
    )

    ds_out["TSTEP"].attrs = dict(
        axis="T",
        long_name="time",
        standard_name="time",
        units="seconds since 1970-1-1 0:0:0",
    )

    ds_out["RUNTIME"] = xr.DataArray(
        TSTEP_vals.copy(),
        dims=("TSTEP",),
        attrs=dict(
            axis="T",
            long_name=(
                "forecast reference time aka run time or analysis time in cf convention"
            ),
            standard_name="forecast_reference_time",
            units="seconds since 1970-1-1 0:0:0",
        ),
    )

    # -------------------------------------------------------------
    # Global IOAPI-like attributes
    # -------------------------------------------------------------
    nrows = int(ds_out.dims["ROW"])
    ncols = int(ds_out.dims["COL"])
    nlays = int(ds_out.dims["LAY"])
    nvars = int(nvar)

    if ncols > 1:
        xcell = np.float32(COL[1] - COL[0])
    else:
        xcell = np.float32(dlon)
    if nrows > 1:
        ycell = np.float32(ROW[1] - ROW[0])
    else:
        ycell = np.float32(dlat)

    xorig = np.float32(COL[0] - 0.5 * xcell)
    yorig = np.float32(ROW[0] - 0.5 * ycell)

    cdate = int(DATEFLAG)
    ctime = int(TIMEFLAG)

    var_list_padded = "".join([f"{v:16s}" for v in var_list])

    ds_out.attrs.update(
        dict(
            IOAPI_VERSION="ioapi-3.2: $Id: init3.F90 200 2021-05-10 14:06:20Z coats $                      ",
            EXEC_ID="WRF3D-hindcast                                                            ",
            FTYPE=int(1),
            CDATE=cdate,
            CTIME=ctime,
            WDATE=cdate,
            WTIME=ctime,
            SDATE=cdate,
            STIME=int(0),
            TSTEP=int(10000),
            NTHIK=int(1),
            NCOLS=ncols,
            NROWS=nrows,
            NLAYS=nlays,
            NVARS=nvars,
            GDTYP=int(1),
            P_ALP=np.float32(0.0),
            P_BET=np.float32(0.0),
            P_GAM=np.float32(0.0),
            XCENT=np.float32(0.0),
            YCENT=np.float32(0.0),
            XORIG=xorig,
            YORIG=yorig,
            XCELL=xcell,
            YCELL=ycell,
            VGTYP=int(4),  # pressure vertical coordinate
            VGTOP=np.float32(0.0),
            VGLVLS=sel_pressures.astype("float32"),
            GDNAM="CAWO_LL025      ",
            UPNAM="M3EDHDR         ",
            **{"VAR-LIST": var_list_padded},
            FILEDESC="CAWO WRF 3D PRES hindcast, selected vars on 0.025 degree lat/lon grid          ",
            HISTORY="",
            Conventions="CF-1.0",
        )
    )

    ds_out.to_netcdf(outfile, format="NETCDF4", unlimited_dims=["TSTEP"])


# Example usage (from Python):
# from post_wrf3d_xesmf import process_wrf3d_xesmf
# process_wrf3d_xesmf("wrfplev_d01_1995-01-02_08:00:00", "post3d_plev_1995-01-02_08.nc")
