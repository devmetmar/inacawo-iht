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
grid_folder = os.environ.get("GRID_DATA")
grdname = grid_folder + 'grid.nc'
ds_grd = xr.open_dataset(grdname)
print('read grd')
df_scoord = pd.read_csv(grid_folder + 'S_COORDINATE_INFO.csv')
theta_s = df_scoord.VALUES[0]
theta_b = df_scoord.VALUES[1]
tcline = df_scoord.VALUES[2]
N = df_scoord.VALUES[3]
vtransform = df_scoord.VALUES[4]
vstretch = df_scoord.VALUES[5]

# Glorys files
glorys_folder = os.environ.get("GLORYS_BASE_DIR")
g_list = sorted(glob.glob(glorys_folder + '*.nc'))

# LO cas2k templates
cawo_folder = os.environ.get("ROMS_FORCING")
lo_list = sorted(glob.glob(cawo_folder + 'f1995*'))

# 
ds_glo = xr.open_dataset(g_list[0])
print('read glorys')
ds_lo = xr.open_dataset(lo_list[0]+'/'+'ocnA0/ocean_ini.nc')
print('read ini template')
ds_clm = xr.open_dataset(lo_list[0]+'/'+'ocnA0/ocean_clm.nc')
print('read clm template')
ds_bry = xr.open_dataset(lo_list[0]+'/'+'ocnA0/ocean_bry.nc')
print('read bry template')
# Load Mercator mean seal level
ds_msl = xr.open_dataset(f'{grid_folder}/mercator_msl.nc')
print('read msl')
os.makedirs(lo_list[0]+'/'+'ocnG', exist_ok = True)

# extrapolate
lon, lat, z, L, M, N, X, Y = Ofun.get_coords(ds_glo)
print('get_coords')
# Iterate through each data variable in the dataset
for var_name in ds_glo.data_vars:
    var = ds_glo[var_name]  # Access the data variable by name
    print(var)
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

glo_list = ['thetao','so','uo','ubar','vo','vbar','zos']

c['temp'] = c.pop('thetao')
c['salt'] = c.pop('so')
c['u'] = c.pop('uo')
c['v'] = c.pop('vo')
c['zeta'] = c.pop('zos')

v3d_list = ['temp', 'salt', 'u', 'v']

v2d_list = ['ubar', 'vbar', 'zeta']

# get sizes
NZ = S['N']; NR = G['M']; NC = G['L']

# Create masks
mr2 = np.ones((NR, NC)) * G['mask_rho'].reshape((NR, NC))
mr3 = np.ones((NZ, NR, NC)) * G['mask_rho'].reshape((1, NR, NC))
mu2 = np.ones((NR, NC-1)) * G['mask_u'].reshape((NR, NC-1))
mu3 = np.ones((NZ, NR, NC-1)) * G['mask_u'].reshape((1, NR, NC-1))
mv2 = np.ones((NR-1, NC)) * G['mask_v'].reshape((NR-1, NC))
mv3 = np.ones((NZ, NR-1, NC)) * G['mask_v'].reshape((1, NR-1, NC))

# Apply masks
for var in v3d_list:
    if var == 'u':
        c[var][mu3==0] = np.nan
    elif var == 'v':
        c[var][mv3==0] = np.nan
    else:    
        c[var][mr3==0] = np.nan

for var in v2d_list:
    if var == 'zeta':
        c[var][mr2==0] = np.nan
    elif var == 'ubar':    
        c[var][mu2==0] = np.nan
    elif var == 'vbar':    
        c[var][mv2==0] = np.nan
        
# Assign and write varibles to template files        
for var in v3d_list:
    if var =='u':
        ds_lo[var][0,:,:,:] = xr.DataArray(c[var], dims=['s_rho', 'eta_u', 'xi_u'])
    elif var == 'v':
        ds_lo[var][0,:,:,:] = xr.DataArray(c[var], dims=['s_rho', 'eta_v', 'xi_v'])
    else:
        ds_lo[var][0,:,:,:] = xr.DataArray(c[var], dims=['s_rho', 'eta_rho', 'xi_rho'])

for var in v2d_list:
    if var == 'ubar':
        ds_lo[var][0,:,:] = xr.DataArray(c[var], dims=['eta_u', 'xi_u'])
    elif var == 'vbar':
        ds_lo[var][0,:,:] = xr.DataArray(c[var], dims=['eta_v', 'xi_v'])
    else:    
        ds_lo[var][0,:,:] = xr.DataArray(c[var], dims=['eta_rho', 'xi_rho'])         

# remove geoid from mercator ssh
ds_lo['zeta'].values = ds_lo['zeta'].values - ds_msl['zeta'].values

ds_lo.to_netcdf(lo_list[0]+'/'+'ocnG/ocean_ini.nc')

# Create clm
    
# Assign and write varibles to template files        
for var in v3d_list:
    ds_clm[var].values = ds_lo[var].values

for var in v2d_list:
    ds_clm[var].values = ds_lo[var].values

ds_clm.to_netcdf(lo_list[0]+'/'+'ocnG/ocean_clm.nc')

# Get the boundary slices and assign to the bry file
brys = ['west','north','south','east']

# Some vars are named differently for bry file
b3d_list = ['temp', 'salt', 'u', 'v']
v2d_list = ['ubar','vbar','zeta']

cont = 0
for var in b3d_list:
    for bry in brys:
        if var == 'u':
           if bry == 'west':
              ds_bry[var + '_' + bry].values = ds_lo[v3d_list[cont]].isel(xi_u=0).values
           elif bry == 'east':
              ds_bry[var + '_' + bry].values = ds_lo[v3d_list[cont]].isel(xi_u=-1).values
           elif bry == 'south':
              ds_bry[var + '_' + bry].values = ds_lo[v3d_list[cont]].isel(eta_u=0).values
           elif bry == 'north':
              ds_bry[var + '_' + bry].values = ds_lo[v3d_list[cont]].isel(eta_u=-1).values
        elif var == 'v':
           if bry == 'west':
              ds_bry[var + '_' + bry].values = ds_lo[v3d_list[cont]].isel(xi_v=0).values
           elif bry == 'east':
              ds_bry[var + '_' + bry].values = ds_lo[v3d_list[cont]].isel(xi_v=-1).values
           elif bry == 'south':
              ds_bry[var + '_' + bry].values = ds_lo[v3d_list[cont]].isel(eta_v=0).values
           elif bry == 'north':
              ds_bry[var + '_' + bry].values = ds_lo[v3d_list[cont]].isel(eta_v=-1).values      
        else:    
           if bry == 'west':
               ds_bry[var + '_' + bry].values = ds_lo[v3d_list[cont]].isel(xi_rho=0).values
           elif bry == 'east':
               ds_bry[var + '_' + bry].values = ds_lo[v3d_list[cont]].isel(xi_rho=-1).values
           elif bry == 'south':
               ds_bry[var + '_' + bry].values = ds_lo[v3d_list[cont]].isel(eta_rho=0).values
           elif bry == 'north':
               ds_bry[var + '_' + bry].values = ds_lo[v3d_list[cont]].isel(eta_rho=-1).values
    cont = cont+1

for var in v2d_list:
    for bry in brys:
        if var == 'ubar':
           if bry == 'west':
              ds_bry[var + '_' + bry].values = ds_lo[var].isel(xi_u=0).values
           elif bry == 'east':
              ds_bry[var + '_' + bry].values = ds_lo[var].isel(xi_u=-1).values
           elif bry == 'south':
              ds_bry[var + '_' + bry].values = ds_lo[var].isel(eta_u=0).values
           elif bry == 'north':
              ds_bry[var + '_' + bry].values = ds_lo[var].isel(eta_u=-1).values 
        elif var == 'vbar':
           if bry == 'west':
              ds_bry[var + '_' + bry].values = ds_lo[var].isel(xi_v=0).values
           elif bry == 'east':
              ds_bry[var + '_' + bry].values = ds_lo[var].isel(xi_v=-1).values
           elif bry == 'south':
              ds_bry[var + '_' + bry].values = ds_lo[var].isel(eta_v=0).values
           elif bry == 'north':
              ds_bry[var + '_' + bry].values = ds_lo[var].isel(eta_v=-1).values      
        else:    
           if bry == 'west':
              ds_bry[var + '_' + bry].values = ds_lo[var].isel(xi_rho=0).values
           elif bry == 'east':
              ds_bry[var + '_' + bry].values = ds_lo[var].isel(xi_rho=-1).values
           elif bry == 'south':
              ds_bry[var + '_' + bry].values = ds_lo[var].isel(eta_rho=0).values
           elif bry == 'north':
              ds_bry[var + '_' + bry].values = ds_lo[var].isel(eta_rho=-1).values

ds_bry.to_netcdf(lo_list[0]+'/'+'ocnG/ocean_bry.nc')
