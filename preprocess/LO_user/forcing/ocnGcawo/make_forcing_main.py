"""
This makes the ocn forcing files for the updated ROMS, including the banas-fennel bio fields.

Testing:

run make_forcing_main.py -g cas6 -r backfill -d 2019.07.04 -f ocn00 -test True

This is the first code that uses the new varinfo.yaml file and the associated method
zrfun.get_varinfo() [around line 328].  The handling of time coordinate names proved to be
especially tricky, so here is what I have learned:

For the clm and bry files the time coordinate for each field has the form [varname]_time,
e.g. salt_time, NO3_time, etc.  This apples to both the climatology and the bry fields,
so the both salt (clm) and salt_east (bry) need their time to be salt_time.  BUT, a few of
the fields have times that break this rule (zeta, ubar, vbar, u, v) and they have time
names that can be found in the Climatology section of varinfo.yaml.  For example ubar uses
v2d_time

The ini file uses state variables, and all of these have there time coordinate called
ocean_time.

"""

from pathlib import Path
import sys
from datetime import datetime, timedelta

from lo_tools import forcing_argfun2 as ffun

Ldir = ffun.intro() # this handles all the argument passing
result_dict = dict()
result_dict['start_dt'] = datetime.now()

# ****************** CASE-SPECIFIC CODE *****************

import xarray as xr
from time import time
import numpy as np

import shutil, os
import pickle
import pandas as pd

from lo_tools import Lfun, zfun, zrfun, Ofun_nc
import Ofun
import Ofun_CTD
import Ofun_bio
    
# defaults
add_CTD = False
do_bio = True
verbose = False

testing_ncks = False
testing_fmrc = False

# This directory is created, along with Info and Data subdirectories, by ffun.intro()
out_dir = Ldir['LOo'] / 'forcing' / Ldir['gridname'] / ('f' + Ldir['date_string']) / Ldir['frc']

# Datetime of the day we are working on
this_dt = datetime.strptime(Ldir['date_string'], Lfun.ds_fmt)    
# this is where all the pre-processed files will go
g_out_dir = out_dir / 'Data'
# This already exists becasue it is created by the initialization, but we make sure it is clean
# so that testing, which does not make a clean version, is more consistent with operational use,
# which does.
Lfun.make_dir(g_out_dir, clean=True)

# process the hycom files, going from the original NetCDF extractions
# to the processed pickled dicts.
V = {}
    
if Ldir['run_type'] == 'backfill':
   # Make a list of files to use from the hycom archive.
   # This is a list of strings corresponding to NetCDF files
   gnc_short_list = Ofun.get_gnc_short_list(this_dt, Ldir)
   # step through those days and convert them to the same format
   # of pickled dicts as used by the forecast
   for fn in gnc_short_list:
       a = Ofun.convert_extraction_oneday(fn)
       dts = datetime.strftime(a['dt'], Lfun.ds_fmt)
       out_fn = g_out_dir / ('h' + dts + '.p')
       pickle.dump(a, open(out_fn, 'wb'))
            
gp_list = sorted([item.name for item in g_out_dir.iterdir()
       if (item.name[0]=='h' and item.name[-2:]=='.p')])
        
    # copy in the coordinates (assume those from first file work)
this_g_dict = pickle.load(open(g_out_dir / gp_list[0], 'rb'))
coord_dict = dict()
for vn in ['lon', 'lat', 'z']:
    coord_dict[vn] = this_g_dict[vn]
pickle.dump(coord_dict, open(g_out_dir / 'coord_dict.p', 'wb'))
    
## filter in time
#Ofun.time_filter(g_out_dir, gp_list, g_out_dir, Ldir)

# extrapolate
lon, lat, z, L, M, N, X, Y = Ofun.get_coords(g_out_dir)
fg_list = sorted([item.name for item in g_out_dir.iterdir()
        if item.name[:2]=='fh'])
print(fg_list)
for fn in fg_list:
    print('-Extrapolating ' + fn)
    in_fn = g_out_dir / fn
    V = Ofun.get_extrapolated(in_fn, L, M, N, X, Y, lon, lat, z, Ldir,
        add_CTD=add_CTD)
    pickle.dump(V, open(g_out_dir / ('x' + fn), 'wb'))

    # and interpolate to ROMS format
    # get grid and S info
    G = zrfun.get_basic_info(Ldir['grid'] / 'grid.nc', only_G=True)
    S_info_dict = Lfun.csv_to_dict(Ldir['grid'] / 'S_COORDINATE_INFO.csv')
    S = zrfun.get_S(S_info_dict)
    # make list of files to process
    xfh_list = sorted([item.name for item in g_out_dir.iterdir()
            if item.name[:3]=='xfh'])
    # HyCOM grid info
    lon, lat, z, L, M, N, X, Y = Ofun.get_coords(g_out_dir)
    # load a dict of hycom fields
    dt_list = []
    count = 0
    c_dict = dict()
    zinds = Ofun.get_zinds(G['h'], S, z)
    for fn in xfh_list:
        print('-Interpolating ' + fn + ' to ROMS grid')
        b = pickle.load(open(g_out_dir / fn, 'rb'))
        dt_list.append(b['dt'])
        c = Ofun.get_interpolated(G, S, b, lon, lat, z, N, zinds)
        c_dict[count] = c
        count += 1
        
    # Write to ROMS forcing files
    # The fields we want to write are in c_dict, whose keys are indices of time.
    # Then c_dict[i] is another dict of arrays at that time, with keys:
    # ['ssh', 'ubar', 'vbar', 'theta', 's3d', 'u3d', 'v3d']
    # and the associated time vector is dt_list (datetimes).
    
    # Here I will write these to the dict V as expected below
    glorys_names = ['ssh', 'ubar', 'vbar', 'theta', 's3d', 'u3d', 'v3d']
    roms_names = ['zeta', 'ubar', 'vbar', 'temp', 'salt', 'u', 'v']
    names_dict = dict(zip(glorys_names, roms_names))
    
    # get sizes
    NZ = S['N']; NR = G['M']; NC = G['L']

    # Make the time vector.
    ot_vec = np.array([Lfun.datetime_to_modtime(item) for item in dt_list])
    NT = len(ot_vec)

    # Create a dict of fields for the state variables.
    V = dict()
    V['zeta'] = np.zeros((NT, NR, NC))
    V['ubar'] = np.zeros((NT, NR, NC-1))
    V['vbar'] = np.zeros((NT, NR-1, NC))
    V['salt'] = np.zeros((NT, NZ, NR, NC))
    V['temp'] = np.zeros((NT, NZ, NR, NC))
    V['u'] = np.zeros((NT, NZ, NR, NC-1))
    V['v'] = np.zeros((NT, NZ, NR-1, NC))
    
    # Fill the V dict
    for ii in range(NT):
        C = c_dict[ii]
        for vnh in glorys_names:
            vnr = names_dict[vnh]
            # note that the : here represents all axes after 0
            # and that it retains the correct shape
            V[vnr][ii, :] = C[vnh]
            

    # Create masks
    mr2 = np.ones((NT, NR, NC)) * G['mask_rho'].reshape((1, NR, NC))
    mr3 = np.ones((NT, NZ, NR, NC)) * G['mask_rho'].reshape((1, 1, NR, NC))
    mu2 = np.ones((NT, NR, NC-1)) * G['mask_u'].reshape((1, NR, NC-1))
    mu3 = np.ones((NT, NZ, NR, NC-1)) * G['mask_u'].reshape((1, 1, NR, NC-1))
    mv2 = np.ones((NT, NR-1, NC)) * G['mask_v'].reshape((1, NR-1, NC))
    mv3 = np.ones((NT, NZ, NR-1, NC)) * G['mask_v'].reshape((1, 1, NR-1, NC))

    # Apply masks
    V['zeta'][mr2==0] = np.nan
    V['ubar'][mu2==0] = np.nan
    V['vbar'][mv2==0] = np.nan
    V['salt'][mr3==0] = np.nan
    V['temp'][mr3==0] = np.nan
    V['u'][mu3==0] = np.nan
    V['v'][mv3==0] = np.nan
    
    # add bio variables if needed
    """
    !------------------------------------------------------------------------------
    ! Fennel et al (2006), Nitrogen-based Biological Model Parameters. Currently,
    ! it can be configured with 15 biological tracers:
    !
    ! idbio( 1)     NO3               Nitrate concentration
    ! idbio( 2)     NH4               Ammonium concentration
    ! idbio( 3)     chlorophyll       Chorophyll concentration
    ! idbio( 4)     phytoplankton     Phytoplankton biomass
    ! idbio( 5)     zooplankton       Zooplankton biomass
    ! idbio( 6)     LdetritusN        Large detritus N-concentration
    ! idbio( 7)     SdetritusN        Small detritus N-concentration
    ! idbio( 8)     LdetritusC        Large detritus C-concentration     if CARBON
    ! idbio( 9)     SdetritusC        Small detritus C-concentration     if CARBON
    ! idbio(10)     TIC               Total inorganic carbon             if CARBON
    ! idbio(11)     alkalinity        Alkalinity                         if CARBON
    ! idbio(12)     oxygen            Oxygen concentration               if OXYGEN
    ! idbio(13)     PO4               Phosphate concentration            if PO4
    ! idbio(14)     RdetritusN        River detritus N-concentration     if RIVER_DON
    ! idbio(15)     RdetritusC        River detritus C-concentration     if RIVER_DON
    !
    !------------------------------------------------------------------------------
    """
    if do_bio:
        bvn_list = ['NO3', 'NH4', 'chlorophyll', 'phytoplankton', 'zooplankton',
                'LdetritusN', 'SdetritusN', 'LdetritusC', 'SdetritusC',
                'TIC', 'alkalinity', 'oxygen']
        salt = V['salt'].copy()
        for bvn in bvn_list:
            V[bvn] = Ofun_bio.create_bio_var(salt, bvn)
    
# Write climatology file making use of zrfun.get_varinfo().
tt0 = time()
out_fn = out_dir / 'ocean_clm.nc'
out_fn.unlink(missing_ok=True)
ds = xr.Dataset()
for vn in V.keys():
    # tt00 = time()
    vinfo = zrfun.get_varinfo(vn, vartype='climatology')
    # print(' -- time to get varinfo: %0.2f sec' % (time()-tt00))
    tname = vinfo['time_name']
    dims = (vinfo['time_name'],) + vinfo['space_dims_tup']
    ds[vn] = (dims, V[vn])
    ds[vn].attrs['units'] = vinfo['units']
    ds[vn].attrs['long_name'] = vinfo['long_name']
    # time coordinate
    ds[tname] = ((tname,), ot_vec)
    ds[tname].attrs['units'] = Lfun.roms_time_units
# and save to NetCDF
Enc_dict = {vn:zrfun.enc_dict for vn in ds.data_vars}
ds.to_netcdf(out_fn, encoding=Enc_dict)
ds.close()
print('- Write clm file: %0.2f sec' % (time()-tt0))
sys.stdout.flush()

if Ldir['start_type'] == 'new':
    # Write initial condition file if needed
    tt0 = time()
    in_fn = out_dir / 'ocean_clm.nc'
    out_fn = out_dir / 'ocean_ini.nc'
    out_fn.unlink(missing_ok=True)
    print(in_fn)
    print(out_fn)
    Ofun_nc.make_ini_file(in_fn, out_fn)
    print('- Write ini file: %0.2f sec' % (time()-tt0))
    sys.stdout.flush()

# Write boundary file
tt0 = time()
in_fn = out_dir / 'ocean_clm.nc'
out_fn = out_dir / 'ocean_bry.nc'
out_fn.unlink(missing_ok=True)
Ofun_nc.make_bry_file(in_fn, out_fn)
print('- Write bry file: %0.2f sec' % (time()-tt0))
sys.stdout.flush()

def print_info(fn):
    print('\n' + str(fn))
    ds = xr.open_dataset(fn)#, decode_times=False)
    print(ds)
    ds.close()

# Check results
if Ldir['start_type'] == 'new':
    nc_list = ['ocean_clm.nc', 'ocean_ini.nc', 'ocean_bry.nc']
else:
    nc_list = ['ocean_clm.nc', 'ocean_bry.nc']
if Ldir['testing']:
    # print info about the files to the screen
    # for fn in nc_list:
    #     print_info(out_dir / fn)
    # open datasets to have a peek
    dsc = xr.open_dataset(out_dir / 'ocean_clm.nc', decode_times=False)
    if Ldir['start_type'] == 'new':
        dsi = xr.open_dataset(out_dir / 'ocean_ini.nc', decode_times=False)
    dsb = xr.open_dataset(out_dir / 'ocean_bry.nc', decode_times=False)
        
result_dict['result'] = 'success'
for fn in nc_list:
    if (out_dir / fn).is_file():
        pass
    else:
       result_dict['result'] = 'fail'

# *******************************************************

result_dict['end_dt'] = datetime.now()
ffun.finale(Ldir, result_dict)