#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Created on Thu Sep  7 10:04:17 2023
Code to create LiveOcean ROMS ocean forcing files based on Parker's LO system'
@author: fsoares
"""

import sys
import os
import xarray as xr
import pandas as pd
import glob
import Ofun
import zrfun
import Lfun
import numpy as np
from scipy.spatial import cKDTree
from scipy.interpolate import interp1d
from scipy.interpolate import griddata

# grid and parameters
grid_folder = '/scratch/cawohdcst/data/grids/'
grdname = grid_folder + 'grid.nc'
ds_grd = xr.open_dataset(grdname)
print(ds_grd)
df_scoord = pd.read_csv(grid_folder + 'S_COORDINATE_INFO.csv')
theta_s = df_scoord.VALUES[0]
theta_b = df_scoord.VALUES[1]
tcline = df_scoord.VALUES[2]
N = df_scoord.VALUES[3]
vtransform = df_scoord.VALUES[4]
vstretch = df_scoord.VALUES[5]

# Glorys files
glorys_folder = '/scratch/cawohdcst/mercator/'
g_list = sorted(glob.glob(glorys_folder + '*.nc'))

# LO cas2k templates
cawo_folder = '/scratch/cawohdcst/data/roms_forcing/'
lo_list = sorted(glob.glob(cawo_folder + 'f1995*'))

# 
ds_glo = xr.open_dataset(g_list[0])
print(ds_glo)

ds_lo = xr.open_dataset(lo_list[0]+'/'+'ocnA0/ocean_ini.nc')
ds_clm = xr.open_dataset(lo_list[0]+'/'+'ocnA0/ocean_clm.nc')
ds_bry = xr.open_dataset(lo_list[0]+'/'+'ocnA0/ocean_bry.nc')

# Load Mercator mean seal level
ds_msl = xr.open_dataset('/scratch/cawohdcst/data/grids/mercator_msl.nc')

os.makedirs(lo_list[0]+'/'+'ocnG', exist_ok = True)

# extrapolate
lon, lat, z, L, M, N, X, Y = Ofun.get_coords(ds_glo)

# Iterate through each data variable in the dataset
for var_name in ds_glo.data_vars:
    var = ds_glo[var_name]  # Access the data variable by name
    if var_name == 'zos':
       var_ext = Ofun.extrap_nearest_to_masked(X, Y, ds_glo[var_name].isel(time=0).values, fld0=0)
       ds_glo[var_name][0,:,:] = var_ext
    else:
       for i in range(len(z)):
           if i > 0:
              var_ext = Ofun.extrap_nearest_to_masked(X, Y, ds_glo[var_name].isel(time=0, depth = i).values, 
                                                      ds_glo[var_name].isel(time=0, depth = i-1).values)
           else:
              var_ext = Ofun.extrap_nearest_to_masked(X, Y, ds_glo[var_name].isel(time=0, depth = i).values,  0)
           ds_glo[var_name][0,i,:,:] = var_ext

print('step 1')

# Create ubar and vbar.
# Note: this is slightly imperfect because the z levels are at the same
# position as the velocity levels.
dz = np.nan * np.ones((N, 1, 1))
dz[1:, 0, 0]= np.diff(z)
dz[0, 0, 0] = dz[1, 0, 0]
    
# account for the fact that the new glorys fields do not show up masked
u3d = np.squeeze(np.ma.masked_where(np.isnan(ds_glo['uo']),ds_glo['uo']))
v3d = np.squeeze(np.ma.masked_where(np.isnan(ds_glo['vo']),ds_glo['vo']))
dz3 = dz * np.ones_like(u3d) # make dz a masked array
ds_glo['ubar'] = ds_glo.zos
ds_glo['vbar'] = ds_glo.zos
# Calculate the vertical average of u3d and v3d
ubar = np.sum(u3d * dz3, axis=0) / np.sum(dz3, axis=0)
vbar = np.sum(v3d * dz3, axis=0) / np.sum(dz3, axis=0)
ubar = ubar.reshape(1, ubar.shape[0], ubar.shape[1])
vbar = vbar.reshape(1, vbar.shape[0], vbar.shape[1])
# Calculate ubar and store it in a DataArray
ubar = xr.DataArray(ubar, coords=ds_glo['zos'].coords, dims=ds_glo['zos'].dims)
vbar = xr.DataArray(vbar, coords=ds_glo['zos'].coords, dims=ds_glo['zos'].dims)

# Assign the updated ubar to ds_glo
ds_glo['ubar'] = ubar
ds_glo['vbar'] = vbar   

print('step2')

# interpolate to ROMS format
# get grid and S info
G = zrfun.get_basic_info(grid_folder + 'grid.nc', only_G=True)
S_info_dict = Lfun.csv_to_dict(grid_folder + 'S_COORDINATE_INFO.csv')
S = zrfun.get_S(S_info_dict)
#zinds = Ofun.get_zinds(G['h'], S, z)
h = G['h']
zr = zrfun.get_z(h, 0*h, S, only_rho=True)
zrf = zr.flatten()
zinds = np.nan * np.ones_like(zrf)
z[0] = -0.01
#z[49] = -6143
if isinstance(z, np.ma.MaskedArray):
    z = z.data
for ii in range(len(z)-1):
    zlo = z[ii]; zhi = z[ii+1]
    mask = (zrf>zhi) & (zrf<=zlo)
    zinds[mask] = ii # this is where the UPPER index is enforced
zinds = zinds.astype(int)
if isinstance(zinds, np.ma.MaskedArray):
    zinds = zinds.data

print('step 3')

#c = Ofun.get_interpolated(G, S, ds_glo, lon, lat, z, N, zinds)

# start input dict
c = {}

# precalculate useful arrays that are used for horizontal interpolation
if isinstance(lon, np.ma.MaskedArray):
    lon = lon.data
if isinstance(lat, np.ma.MaskedArray):
    lat = lat.data
Lon, Lat = np.meshgrid(lon,lat)
XYin = np.array((Lon.flatten(), Lat.flatten())).T
XYr = np.array((G['lon_rho'].flatten(), G['lat_rho'].flatten())).T
h = G['h']
#IMr = cKDTree(XYin).query(XYr)[1]

print ('step 4')

# 2D fields
b = ds_glo
for vn in ['zos', 'ubar', 'vbar']:
    vv = griddata(XYin, b[vn][0,:,:].values.flatten(), XYr, method='linear').reshape(h.shape)
    if vn == 'ubar':
        vv = (vv[:,:-1] + vv[:,1:])/2
    elif vn == 'vbar':
        vv = (vv[:-1,:] + vv[1:,:])/2
    vvc = vv.copy()
    # always a good idea to make sure dict entries are not just pointers
    # to arrays that might be changed later, hence the .copy()
    c[vn] = vvc
    Ofun.checknan(vvc)

print('step 5')

# 3D fields
# create intermediate arrays which are on the ROMS lon_rho, lat_rho grid
# but have the Mercator vertical grid (N layers)
F = np.nan * np.ones(((N,) + h.shape))
vi_dict = {}
for vn in ['thetao', 'so', 'uo', 'vo']:
    FF = F.copy()
    print(vn)
    for nn in range(N):
        print(nn)
        vin = b[vn][0,nn,:,:].values.flatten()
        FF[nn,:,:] = griddata(XYin, vin, XYr, method='linear').reshape(h.shape)
    Ofun.checknan(FF)
    vi_dict[vn] = FF

# do the vertical interpolation from Mercator to ROMS z positions
for vn in ['thetao', 'so', 'uo', 'vo']:
    vi = vi_dict[vn]
    # Here the vertical nearest method is replaced by a linear interpolation
    NZ_out, NR, NC = zr.shape
    NZ_in = z.size

    vi_interp = np.full((NZ_out, NR, NC), np.nan)  # output array

    # Because zr is deep->shallow, flip zr vertically to shallow->deep for interpolation
    zr_flipped = zr[::-1, :, :]  # shape (70, 1128, 2038), shallow->deep order
    print('Vertical interpolation')
    for i in range(NR):
        for j in range(NC):
            # vi vertical profile at (i,j)
            vi_col = vi[:, i, j]

            # skip if all nan
            if np.all(np.isnan(vi_col)):
                continue

            # Build interpolator on z (shallow->deep)
            f = interp1d(z, vi_col, bounds_error=False, fill_value=np.nan)

            # interpolate at shallow->deep zr points
            interp_col = f(zr_flipped[:, i, j])

            # flip back to deep->shallow vertical order
            vi_interp[:, i, j] = interp_col[::-1]
           
    vvc = vi_interp.copy()
    if vn == 'uo':
        vvc = (vvc[:,:,:-1] + vvc[:,:,1:])/2
    elif vn == 'vo':
        vvc = (vvc[:,:-1,:] + vvc[:,1:,:])/2
    Ofun.checknan(vvc)
    c[vn] = vvc
print('step 6')