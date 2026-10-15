#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
post_roms2d_xesmf.py

Postprocess COAWST/ROMS history file into IOAPI-like OCEAN2D on CAWO_LL025 grid.

Writes ONLY:
  temp_sur, salt_sur, u_sur_eastward, v_sur_northward, zeta
  + wave vars remapped from left-column SWAN vars embedded in ROMS file.

No surface fluxes.
Assumes u_eastward and v_northward already exist on rho grid.
"""

from __future__ import annotations

import os
import numpy as np
import pandas as pd
import xarray as xr
import xesmf as xe

FILL = np.float32(-9.999e36)

# Left (raw) -> Right (postprocessed) mapping from your SWAN cfg
WAVE_REMAP = {
    "Hwave": "sig_wave_height",
    "Dwave": "mean_wave_dir",
    "Dwavep": "peak_wave_dir",
    "Lwave": "mean_wave_len",
    "Lwavep": "peak_wave_len",
    "Pwave_top": "peak_wave_period",
    "HsPT01": "wind_sea_swht",
    "TpPT01": "wind_sea_perd",
    "DrPT01": "wind_sea_dir",
    "WlPT01": "wind_sea_wlen",
    "HsPT02": "prim_swell_swht",
    "TpPT02": "prim_swell_perd",
    "DrPT02": "prim_swell_dir",
    "WlPT02": "prim_swell_wlen",
}


def _build_cawo_ll025_grid():
    # Matches forecast grid metadata: centers start at 90, -15; 2201x1201 at 0.025
    ncols, nrows = 2201, 1201
    d = 0.025
    lon_1d = 90.0 + d * np.arange(ncols, dtype="float64")
    lat_1d = -15.0 + d * np.arange(nrows, dtype="float64")
    lon2, lat2 = np.meshgrid(lon_1d, lat_1d)
    grid_out = xr.Dataset(
        {"lon": (("y", "x"), lon2), "lat": (("y", "x"), lat2)}
    )
    return lon_1d, lat_1d, grid_out


def _pick_time0(ds: xr.Dataset) -> pd.Timestamp:
    if "ocean_time" in ds:
        return pd.to_datetime(ds["ocean_time"].values[0])
    if "time" in ds:
        return pd.to_datetime(ds["time"].values[0])
    raise KeyError("No time coordinate found (expected ocean_time or time).")


def _to_2d_at_surface(da: xr.DataArray) -> xr.DataArray:
    """
    Reduce any ROMS variable to a single 2D slice suitable for regridding.
    - Select ocean_time/time index 0 if present
    - Select surface from s_rho or s_w if present
    - Drop any leftover length-1 dims
    """
    for tdim in ("ocean_time", "time"):
        if tdim in da.dims:
            da = da.isel({tdim: 0})

    if "s_rho" in da.dims:
        da = da.isel(s_rho=-1)
    if "s_w" in da.dims:
        da = da.isel(s_w=-1)

    # If there are still extra dims, keep the last two as horizontal
    # and squeeze everything else (robust fallback).
    da = da.squeeze(drop=True)

    if da.ndim != 2:
        # Try to coerce: take first index along remaining dims until 2D
        for d in list(da.dims):
            if da.ndim <= 2:
                break
            da = da.isel({d: 0})
        da = da.squeeze(drop=True)

    if da.ndim != 2:
        raise ValueError(f"Could not reduce to 2D. Final dims: {da.dims}, shape={da.shape}")

    return da


def process_ocean2d_xesmf(infile: str, outfile: str, include_waves: bool = True):
    ds = xr.open_dataset(infile, decode_times=True)

    t = _pick_time0(ds)
    tstep_val = np.float64(pd.Timestamp(t).timestamp())
    TSTEP_vals = np.array([tstep_val], dtype="float64")

    # Target grid
    COL_1d, ROW_1d, grid_out = _build_cawo_ll025_grid()

    # Input grid must be 2D lon/lat on rho points
    if "lon_rho" not in ds or "lat_rho" not in ds:
        raise KeyError("Expected lon_rho/lat_rho in ROMS file for regridding.")

    grid_in = xr.Dataset(
        {
            "lon": (("eta_rho", "xi_rho"), ds["lon_rho"].values.astype("float64")),
            "lat": (("eta_rho", "xi_rho"), ds["lat_rho"].values.astype("float64")),
        }
    )

    regridder = xe.Regridder(grid_in, grid_out, "bilinear", periodic=False, reuse_weights=False)

    def regrid2d(varname: str) -> np.ndarray:
        da = _to_2d_at_surface(ds[varname])
        out = regridder(da.astype("float64"))
        vals = out.values.astype("float32")
        # add (TSTEP, LAY) leading dims
        return vals[None, None, :, :]

    # Required ocean vars
    needed = ["temp", "salt", "u_eastward", "v_northward", "zeta"]
    for v in needed:
        if v not in ds:
            raise KeyError(f"Missing required variable in ROMS file: {v}")

    out_vars = {}

    out_vars["temp_sur"] = xr.DataArray(
        regrid2d("temp"), dims=("TSTEP", "LAY", "ROW", "COL"), name="temp_sur"
    )
    out_vars["salt_sur"] = xr.DataArray(
        regrid2d("salt"), dims=("TSTEP", "LAY", "ROW", "COL"), name="salt_sur"
    )
    out_vars["u_sur_eastward"] = xr.DataArray(
        regrid2d("u_eastward"), dims=("TSTEP", "LAY", "ROW", "COL"), name="u_sur_eastward"
    )
    out_vars["v_sur_northward"] = xr.DataArray(
        regrid2d("v_northward"), dims=("TSTEP", "LAY", "ROW", "COL"), name="v_sur_northward"
    )
    out_vars["zeta"] = xr.DataArray(
        regrid2d("zeta"), dims=("TSTEP", "LAY", "ROW", "COL"), name="zeta"
    )

    # Waves (already in ROMS file as left-column names)
    if include_waves:
        for raw_name, out_name in WAVE_REMAP.items():
            if raw_name in ds:
                out_vars[out_name] = xr.DataArray(
                    regrid2d(raw_name),
                    dims=("TSTEP", "LAY", "ROW", "COL"),
                    name=out_name,
                )

    ds_out = xr.Dataset(out_vars)

    # Coordinates
    ds_out = ds_out.assign_coords(
        TSTEP=("TSTEP", TSTEP_vals.astype("float64")),
        ROW=("ROW", ROW_1d.astype("float64")),
        COL=("COL", COL_1d.astype("float64")),
        LAY=("LAY", np.array([0.0], dtype="float64")),
    )

    # lon/lat vars (no FillValue)
    ds_out["lon"] = xr.DataArray(
        ds_out["COL"].values.astype("float32"),
        dims=("COL",),
        attrs=dict(axis="X", long_name="longitude", standard_name="longitude", units="degrees_east", grid_mapping="geographic"),
    )
    ds_out["lat"] = xr.DataArray(
        ds_out["ROW"].values.astype("float32"),
        dims=("ROW",),
        attrs=dict(axis="Y", long_name="latitude", standard_name="latitude", units="degrees_north", grid_mapping="geographic"),
    )
    ds_out["geographic"] = xr.DataArray(np.array(" ", dtype="S1"), attrs=dict(grid_mapping_name="latitude_longitude"))

    ds_out["ROW"].attrs = dict(axis="Y", long_name="latitude", standard_name="projection_y_coordinate", units="degrees_north", grid_mapping="geographic")
    ds_out["COL"].attrs = dict(axis="X", long_name="longitude", standard_name="projection_x_coordinate", units="degrees_east", grid_mapping="geographic")
    ds_out["LAY"].attrs = dict(axis="Z", standard_name="depth_below_geoid", units="m")

    # Add FillValue to data vars only
    for v in ds_out.data_vars:
        if v in ("lon", "lat", "geographic", "TFLAG", "RUNTIME"):
            continue
        if "ROW" in ds_out[v].dims and "COL" in ds_out[v].dims:
            ds_out[v] = ds_out[v].astype("float32")
            ds_out[v].attrs["_FillValue"] = FILL

    # Time flags
    YYYY, DDD = int(t.year), int(t.dayofyear)
    HH, MM, SS = int(t.hour), int(t.minute), int(t.second)
    DATEFLAG = YYYY * 1000 + DDD
    TIMEFLAG = HH * 10000 + MM * 100 + SS

    var_list = list(ds_out.data_vars.keys())
    nvar = len(var_list)

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

    ds_out["TSTEP"].attrs = dict(axis="T", long_name="time", standard_name="time", units="seconds since 1970-1-1 0:0:0")
    ds_out["RUNTIME"] = xr.DataArray(
        TSTEP_vals.copy(),
        dims=("TSTEP",),
        attrs=dict(axis="T", long_name="forecast reference time aka run time or analysis time in cf convention",
                   standard_name="forecast_reference_time", units="seconds since 1970-1-1 0:0:0"),
    )

    # Global attributes (IOAPI-like minimal)
    xcell = np.float32(ds_out["COL"].values[1] - ds_out["COL"].values[0])
    ycell = np.float32(ds_out["ROW"].values[1] - ds_out["ROW"].values[0])
    xorig = np.float32(ds_out["COL"].values[0] - 0.5 * xcell)
    yorig = np.float32(ds_out["ROW"].values[0] - 0.5 * ycell)
    var_list_padded = "".join([f"{v:16s}" for v in var_list])

    ds_out.attrs.update(
        dict(
            IOAPI_VERSION="ioapi-3.2: $Id: init3.F90 200 2021-05-10 14:06:20Z coats $                      ",
            EXEC_ID="OCEAN2D-hindcast                                                          ",
            FTYPE=int(1),
            CDATE=int(DATEFLAG),
            CTIME=int(TIMEFLAG),
            WDATE=int(DATEFLAG),
            WTIME=int(TIMEFLAG),
            SDATE=int(DATEFLAG),
            STIME=int(0),
            TSTEP=int(10000),
            NTHIK=int(1),
            NCOLS=int(ds_out.dims["COL"]),
            NROWS=int(ds_out.dims["ROW"]),
            NLAYS=int(ds_out.dims["LAY"]),
            NVARS=int(nvar),
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
            VGTYP=int(3),
            VGTOP=np.float32(0.0),
            VGLVLS=np.array([-1.0, -0.9857143], dtype="float32"),
            GDNAM="CAWO_LL025      ",
            UPNAM="M3EDHDR         ",
            **{"VAR-LIST": var_list_padded},
            FILEDESC="CAWO ROMS/SWAN 2D surface data file, 0.025 degree lat/lon grid",
            HISTORY="",
            Conventions="CF-1.0",
        )
    )

    os.makedirs(os.path.dirname(outfile), exist_ok=True)
    ds_out.to_netcdf(outfile, format="NETCDF4", unlimited_dims=["TSTEP"])
