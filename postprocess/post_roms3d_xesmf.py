#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Post-process ROMS 3D outputs to IOAPI-style 3D files on the CAWO lat/lon grid.

- Vertically interpolate from ROMS sigma coordinates to fixed z levels using
  xroms + xgcm.
- Horizontally regrid to a regular 0.025 deg lat/lon grid using xESMF.
- Write IOAPI-like output matching the OCEAN3D example structure, with:

    TEMP        (sea_water_potential_temperature)
    SALT        (sea_water_salinity)
    Uearth_RHO  (eastward_sea_water_velocity)
    Vearth_RHO  (northward_sea_water_velocity)
    W_RHO       (upward_sea_water_velocity)

Input variables (if present in ROMS file):
    temp
    salt
    u_eastward
    v_northward
    w

Vertical levels (m, negative downward):
    0, -10, -25, -50, -100, -250, -500, -1000, -2000
"""

import numpy as np
import pandas as pd
import xarray as xr
import xesmf as xe
import xroms


def process_roms3d_xesmf(
    infile,
    outfile,
    target_z_levels=(0.0, -10.0, -25.0, -50.0, -100.0, -250.0, -500.0, -1000.0, -2000.0),
    lon_min=90.0,
    lon_max=145.0,
    lat_min=-15.0,
    lat_max=15.0,
    dlon=0.025,
    dlat=0.025,
):
    """
    Process a single ROMS history file into an IOAPI-like 3D file.

    Memory-optimized:
    - Open ROMS with chunks (no full in-memory load).
    - Use xroms/xgcm to interpolate one z level at a time.
    - Regrid each 2D z-slice immediately to lat/lon instead of
      holding a big (LAY, eta, xi) array.
    """

    # -------------------------------------------------------------
    # Open ROMS with chunks to avoid loading the whole file at once
    # -------------------------------------------------------------
    ds_roms = xr.open_dataset(infile, chunks={"ocean_time": 1})
    if "ocean_time" not in ds_roms:
        raise KeyError("Expected 'ocean_time' in ROMS file.")

    # Attach xroms / xgcm grid, but avoid heavy extras
    ds, xgrid = xroms.roms_dataset(
        ds_roms,
        include_cell_volume=False,  # avoid huge cell_volume variable
        include_Z0=True,            # enough info to compute z_rho / z_w
    )
    ds.xroms.set_grid(xgrid)

    # Model time (we only use the first time index in this file)
    t0 = ds["ocean_time"].isel(ocean_time=0).values
    ds_time = pd.to_datetime(t0)

    # -------------------------------------------------------------
    # Source horizontal grid (ROMS rho-points)
    # -------------------------------------------------------------
    if ("lon_rho" not in ds) or ("lat_rho" not in ds):
        raise KeyError("Expected 'lon_rho' and 'lat_rho' in ROMS file.")

    lon_rho = ds["lon_rho"]
    lat_rho = ds["lat_rho"]

    # Some ROMS outputs have time on lon_rho/lat_rho, others do not
    if "ocean_time" in lon_rho.dims:
        src_lon = lon_rho.isel(ocean_time=0, drop=True)
    else:
        src_lon = lon_rho

    if "ocean_time" in lat_rho.dims:
        src_lat = lat_rho.isel(ocean_time=0, drop=True)
    else:
        src_lat = lat_rho

    # -------------------------------------------------------------
    # Target CAWO lat/lon grid
    # -------------------------------------------------------------
    lon_1d = np.arange(lon_min, lon_max + 0.5 * dlon, dlon)
    lat_1d = np.arange(lat_min, lat_max + 0.5 * dlat, dlat)
    ncols = lon_1d.size
    nrows = lat_1d.size

    tgt_lon2d, tgt_lat2d = np.meshgrid(lon_1d, lat_1d)

    COL = lon_1d.astype("float64")
    ROW = lat_1d.astype("float64")

    # -------------------------------------------------------------
    # Time handling for IOAPI: seconds since 1970-01-01
    # -------------------------------------------------------------
    TSTEP_vals = np.array(
        [
            (
                np.datetime64(ds_time)
                - np.datetime64("1970-01-01T00:00:00")
            )
            / np.timedelta64(1, "s")
        ],
        dtype="float64",
    )

    # -------------------------------------------------------------
    # Vertical levels and z_rho / z_w
    # -------------------------------------------------------------
    target_z = np.array(target_z_levels, dtype="float64")
    nlay = target_z.size

    if "z_rho" not in ds:
        raise KeyError("Expected 'z_rho' in ROMS/xroms dataset.")
    z_rho = ds["z_rho"]
    if "ocean_time" in z_rho.dims:
        z_rho_t0 = z_rho.isel(ocean_time=0)
    else:
        z_rho_t0 = z_rho

    # We will use z_w only for w
    if "z_w" in ds:
        z_w = ds["z_w"]
        if "ocean_time" in z_w.dims:
            z_w_t0 = z_w.isel(ocean_time=0)
        else:
            z_w_t0 = z_w
    else:
        z_w_t0 = None

    # -------------------------------------------------------------
    # xESMF regridder: ROMS rho grid -> CAWO lat/lon grid
    # (weights are computed once per call and reused for all layers)
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
    # Helper: z-slice + regrid, one depth at a time (memory-friendly)
    # -------------------------------------------------------------
    def zslice_and_regrid(varname, use_w=False):
        """
        Interpolate a ROMS 3D variable to target_z and regrid each z-slice.

        If use_w=True, use z_w for the vertical coordinate (for 'w').
        Otherwise, use z_rho.

        Special case:
        - For zlev ~ 0 m, we do NOT call xgrid.transform. We simply take
          the top ROMS layer (s_rho = -1 or s_w = -1) and treat it as the
          "0 m" level, to avoid issues with SSH / dry cells.
        """
        if varname not in ds:
            return None

        var3d = ds[varname]
        if "ocean_time" in var3d.dims:
            src3d = var3d.isel(ocean_time=0)
        else:
            src3d = var3d

        # Choose the vertical coordinate to match the variable's native grid
        if use_w:
            if z_w_t0 is None:
                raise KeyError("Expected 'z_w' in ROMS/xroms dataset for w.")
            z_vert = z_w_t0
            vertical_dim = "s_w"
        else:
            z_vert = z_rho_t0
            vertical_dim = "s_rho"

        # Fallback: if vertical_dim name is not in src3d, try to infer it
        if vertical_dim not in src3d.dims:
            # heuristics: take the first dim that is not a horizontal dim
            horiz_dims = {"eta_rho", "xi_rho", "eta_u", "xi_u", "eta_v", "xi_v"}
            cand = [d for d in src3d.dims if d not in horiz_dims]
            if not cand:
                raise ValueError(
                    f"Could not determine vertical dimension for {varname}. "
                    f"Dims: {src3d.dims}"
                )
            vertical_dim = cand[0]

        out_vals = np.empty((nlay, nrows, ncols), dtype="float32")

        for k, zlev in enumerate(target_z):
            # 1D target array of length 1 for this depth
            # For z ~ 0 m, just take the surface ROMS layer
            if abs(zlev) < 1e-6:
                # Take top level: s_rho=-1 for rho vars, s_w=-1 for w
                field2d = src3d.isel({vertical_dim: -1})
            else:
                target_da = xr.DataArray(
                    [zlev],
                    dims=("Zt",),
                    name="z_target",
                )

                # Vertical interpolation along Z
                out_zk = xgrid.transform(
                    src3d,
                    "Z",
                    target_da,
                    target_data=z_vert,
                )
                # out_zk dims: ("Zt", "eta_rho", "xi_rho"), length-1 in Zt
                field2d = out_zk.isel(Zt=0)

            # Regrid to CAWO grid
            regridded = regridder(field2d)
            out_vals[k, :, :] = regridded.astype("float32").values

        # Add leading TSTEP=1 dimension
        out_vals = out_vals[np.newaxis, ...]  # (1, LAY, ROW, COL)
        return out_vals

    # -------------------------------------------------------------
    # Build output variables: TEMP, SALT, Uearth_RHO, Vearth_RHO, W_RHO
    # -------------------------------------------------------------
    out_vars = {}

    vals = zslice_and_regrid("temp", use_w=False)
    if vals is not None:
        out_vars["TEMP"] = xr.DataArray(
            vals, dims=("TSTEP", "LAY", "ROW", "COL"), name="TEMP"
        )

    vals = zslice_and_regrid("salt", use_w=False)
    if vals is not None:
        out_vars["SALT"] = xr.DataArray(
            vals, dims=("TSTEP", "LAY", "ROW", "COL"), name="SALT"
        )

    vals = zslice_and_regrid("u_eastward", use_w=False)
    if vals is not None:
        out_vars["Uearth_RHO"] = xr.DataArray(
            vals, dims=("TSTEP", "LAY", "ROW", "COL"), name="Uearth_RHO"
        )

    vals = zslice_and_regrid("v_northward", use_w=False)
    if vals is not None:
        out_vars["Vearth_RHO"] = xr.DataArray(
            vals, dims=("TSTEP", "LAY", "ROW", "COL"), name="Vearth_RHO"
        )

    vals = zslice_and_regrid("w", use_w=True)
    if vals is not None:
        out_vars["W_RHO"] = xr.DataArray(
            vals, dims=("TSTEP", "LAY", "ROW", "COL"), name="W_RHO"
        )

    if not out_vars:
        raise RuntimeError(
            "No output variables created. "
            "Check that temp, salt, u_eastward, v_northward, w exist in the ROMS file."
        )

    # -------------------------------------------------------------
    # Build ds_out, coords, and basic coordinate attrs
    # -------------------------------------------------------------
    ds_out = xr.Dataset(out_vars)

    ds_out = ds_out.assign_coords(
        TSTEP=("TSTEP", TSTEP_vals.astype("float64")),
        ROW=("ROW", ROW),
        COL=("COL", COL),
        LAY=("LAY", target_z.astype("float32")),
    )

    # 1D lat/lon on ROW/COL
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
        standard_name="depth_below_geoid",
        units="m",
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
        "TEMP",
        dict(
            long_name="TEMP",
            standard_name="sea_water_potential_temperature",
            units="Celsius",
            var_desc="Ocean potential temperature on z-levels, scalar, series",
        ),
    )
    set_var_attrs(
        "SALT",
        dict(
            long_name="SALT",
            standard_name="sea_water_salinity",
            units="1",
            var_desc="Ocean salinity on z-levels, scalar, series",
        ),
    )
    set_var_attrs(
        "Uearth_RHO",
        dict(
            long_name="Uearth_RHO",
            standard_name="eastward_sea_water_velocity",
            units="m s-1",
            var_desc="Ocean U current eastward on z-levels, scalar, series",
        ),
    )
    set_var_attrs(
        "Vearth_RHO",
        dict(
            long_name="Vearth_RHO",
            standard_name="northward_sea_water_velocity",
            units="m s-1",
            var_desc="Ocean V current northward on z-levels, scalar, series",
        ),
    )
    set_var_attrs(
        "W_RHO",
        dict(
            long_name="W_RHO",
            standard_name="upward_sea_water_velocity",
            units="m s-1",
            var_desc="w-velocity on z-levels, scalar, series",
        ),
    )

    # -------------------------------------------------------------
    # TFLAG and RUNTIME (IOAPI-style)
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

    # pad VAR-LIST to 16-char fields
    var_list_padded = "".join(f"{v:16s}" for v in var_list)

    ds_out.attrs.update(
        dict(
            IOAPI_VERSION="ioapi-3.2: $Id: init3.F90 200 2021-05-10 14:06:20Z coats $                      ",
            EXEC_ID="ROMS3D-hindcast                                                          ",
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
            VGTYP=int(5),  # z-level vertical coordinate
            VGTOP=np.float32(0.0),
            VGLVLS=target_z.astype("float32"),
            GDNAM="CAWO_LL025      ",
            UPNAM="M3EDHDR         ",
            **{"VAR-LIST": var_list_padded},
            FILEDESC=(
                "CAWO ROMS 3D zlevel data file, selected vars on 0.025 deg lat/lon grid"
            ),
            HISTORY="",
            Conventions="CF-1.0",
        )
    )

    # -------------------------------------------------------------
    # Write file
    # -------------------------------------------------------------
    ds_out.to_netcdf(outfile, format="NETCDF4", unlimited_dims=["TSTEP"])
