import xarray as xr
import xroms
import numpy as np

ds_roms = xr.open_dataset("forecast_examples/cawo_g2.8.1_his_20251127_18_00079.nc")

ds, xgrid = xroms.roms_dataset(ds_roms, include_cell_volume=True, include_Z0=True)
ds.xroms.set_grid(xgrid)

target = xr.DataArray(np.array([-1500]), dims=("z",), name="z")

out = xgrid.transform(
        ds["temp"],
        "Z",
        target,
        target_data=ds.z_rho
)

temp_1500 = out.isel(z=0, drop=True)
ds = ds["temp"].isel(s_rho=-1)
ds.values = temp_1500
ds = ds.drop_vars("ocean_time")

ds.to_netcdf("test_temp_1500.nc")
