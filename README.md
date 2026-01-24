# InaCAWO Hindcast Mode

!!! warning
    The hands-on in this section is intended for internal BMKG users, non-BMKG users may still be able to follow the tutorial without access to the computational resources.

!!! info
    This hands-on tutorial is designed to run on the MDC Supercomputer using the `cawohdcst_ft2` user account.

    Please contact the team for further information at [produksi.maritim@bmkg.go.id](mailto:produksi.maritim@bmkg.go.id).

??? info "Contents ..."
    ### Contents

    - [Main differences from the forecast system](#main-differences-from-the-forecast-system)
        - [Preprocessing Workflow](#preprocessing-workflow)
        - [Physical Considerations](#physical-considerations)

    - [General Workflow](#general-workflow)

    - [Configurations](#configurations)

    - [Dependencies](#dependencies)
        - [Conda Environment](#conda-environment)
        - [LiveOcean](#liveocean)

    - [Preparing The Working Directory](#preparing-the-working-directory)

    - [Global Reanalysis Data Acquisition](#global-reanalysis-data-acquisition)
        - [ERA5 Atmospheric Data](#era5-atmospheric-data)
        - [ERA5 Waves Data](#era5-waves-data)
        - [Mercator GLORYS12V1 Data](#mercator-glorys12v1-data)

    - [Pre Processing](#pre-processing)
        - [WRF Forcing Files](#wrf-forcing-files)
        - [SWAN Forcing Files](#swan-forcing-files)
        - [ROMS Forcing Files](#roms-forcing-files)

    - [Running The Hindcast](#running-the-hindcast)
        - [Compiling COAWST](#compiling-coawst)
        - [Running Scheme](#running-scheme)
        - [Modifying Namelist Files](#modifying-namelist-files)
        - [Copying input files](#copying-input-files)
        - [Running a day cycle](#running-a-day-cycle)
        - [Running automation](#running-automation)

    - [Post Processing](#post-processing)
        - [WRF2D](#wrf2d)
        - [WRF3D](#wrf3d)
        - [Ocean2D](#ocean2d)
        - [Ocean3D](#ocean3d)

    - [Summary and Common Problems](#summary-and-common-problems)

## Main differences from the forecast system

### Preprocessing workflow

The forecast input data is available only near each forecast cycle time. Thus, the data must be downloaded and processed as soon as possible so that the forecast outputs are generated in a timely manner.

To automate this process and ensure the results are delivered within the required time frame, the forecast system relies heavily on ROME tools. This suite of tools consists of complex driver scripts and watchdogs that manage each step of the workflow.

Although the hindcast workflow is based on the same processes used in the operational forecasts, it is greatly simplified because all input data for the 30-year period is already available. The hindcast components can run independently: while the hindcast is advancing through a given day, the reanalysis downloads and forcing-file generation can proceed for future dates. Likewise, postprocessing and model–data comparisons can be performed for earlier periods once their hindcast cycles have finished.

### Physical Considerations

The model configurations remain essentially the same, with one major exception: the ROMS open boundary conditions (OBCs).

In the forecast system, the velocities use zero-gradient boundary conditions, meaning the model does not ingest external information and simply extrapolates interior values to the boundary. This approach is acceptable for forecasts because each cycle spans only 10 days. However, in a long-term simulation the internal velocity fields will gradually drift away from realistic conditions. To address this, the hindcast uses radiation + nudging OBCs for the velocities.

For long simulations, it is also recommended to apply a light nudging zone near the boundaries, consistent with the sponge-layer (Marchesiello et al., 2003). Accordingly, a climatology nudging was applied to the four grid points closest to each boundary. The nudging was applied to temperature, salinity, baroclinic and barotropic velocities, and sea surface height, all obtained from the Glorys Reanalysis.

Additionally, the boundary conditions for SSH and barotropic velocities were updated to the Flather–Chapman combination, which is known to be very stable when used together with the OBC options noted above.

## General Workflow

``` mermaid
flowchart TD

A@{ shape: circle, label: "Start" } 
--> B{Check conda envs}
B -- Not available --> C[Install conda and create environment]
C --> B
B -- Available --> E[Download Global Data]

subgraph PreProcessing
    E --> F@{ shape: lean-r, label: "Global data from ERA5 Atm, ERA5 Wave, and GLORYS Mercator Ocean" }
    F --> G[Generate Forcing Files]
    G --> H@{ shape: lean-r, label: "Forcing Files for WRF, SWAN, ROMS" }
end

subgraph MainProcessing
    I{Running Hindcast}
    I -- Running Day 1 --> J[Compile COAWST with Ramp Tides] --> K@{ shape: lean-r, label: "Binary CoawstM" }
    I -- Running after Day 1 --> L[Compile COAWST without Ramp Tides] --> M@{ shape: lean-r, label: "Binary CoawstM"}
    
    N@{ shape: lean-r, label: "Edited namelist files for WRF, SWAN, ROMS, and COAWST"}
    
    O[Model integration]

    K --> P@{ shape: circle, label: "OR" } 
    M --> P@{ shape: circle, label: "OR" } 
    P --> O
    N --> O
    H --> O
    O --> Q@{ shape: lean-r, label: "Raw Output" }
end

subgraph PostProcessing
    Q --> R[PostProcessing]
    R --> S@{shape: lean-r, label: "Processed output"}
end

S --> T@{shape: circle, label: "End"}

PreProcessing --> MainProcessing --> PostProcessing
```

## Configurations

=== "Model - COAWST"
    - WRF 
    - ROMS
    - SWAN
=== "Domain and Resolution"
    - 15S to 15N, 90E to 145E
    - ~3km
=== "Static Input"
    - Land-Use/Land-Cover: Friedl and Sulla-Menashe (2015)
    - Soils texture: Dy and Fung (2016)
    - Terrain: GMTED2010
    - Coastal boundaries: GSHHG (Wessel and Smith, 1996)
    - Climatological River Discharge: Global Data Runoff Center or Global Annual River Discharge Dataset
    - Bathymetry: GEBCO 2021 (~450m)
    - Tides: TPXO (Egbert and Erofeeva, 2002)
=== "Dynamic Input"
    - Atmosphere (surface and pressure levels): ECMWF ERA5
    - Ocean: Mercator reanalyses GLORYS12V2.1
    - Waves: ECMWF ERA5 Waves


## Dependencies

### Conda Environment
Downloading, preprocessing, and postprocessing scripts are based on python tools. To ensure reproducibility of the processes, conda environments should be created and activated previously.

In `cawohdcst_ft2` home directory, `conda`'s source code is available in `/home/cawohdcst_ft2/opt/miniforge3`.

`conda` is intentionally not activated by default (to avoid cluttering `.bashrc`) in order to keep working environment clean. Hence, you need to activate it by typing the following command.

```bash
source /home/cawohdcst_ft2/opt/miniforge3/etc/profile.d/conda.sh
conda activate
```

??? info "Validating conda"
    You should see the output like this if you type `conda info`
    ```bash
    (base) [cawohdcst_ft2@mdclogin1 ~]$ conda info

        active environment : base
        active env location : /home/cawohdcst_ft2/opt/miniforge3
                shell level : 1
        user config file : /home/cawohdcst_ft2/.condarc
    populated config files : /home/cawohdcst_ft2/opt/miniforge3/.condarc
            conda version : 25.11.0
        conda-build version : not installed
            python version : 3.12.12.final.0
                    solver : libmamba (default)
        virtual packages : __archspec=1=zen2
                            __conda=25.11.0=0
                            __cuda=0=0
                            __glibc=2.28=0
                            __linux=4.18.0=0
                            __unix=0=0
        base environment : /home/cawohdcst_ft2/opt/miniforge3  (writable)
        conda av data dir : /home/cawohdcst_ft2/opt/miniforge3/etc/conda
    conda av metadata url : None
            channel URLs : https://conda.anaconda.org/conda-forge/linux-64
                            https://conda.anaconda.org/conda-forge/noarch
            package cache : /home/cawohdcst_ft2/opt/miniforge3/pkgs
                            /home/cawohdcst_ft2/.conda/pkgs
        envs directories : /home/cawohdcst_ft2/opt/miniforge3/envs
                            /home/cawohdcst_ft2/.conda/envs
                platform : linux-64
                user-agent : conda/25.11.0 requests/2.32.5 CPython/3.12.12 Linux/4.18.0-348.23.1.el8_5.x86_64 rhel/8.5 glibc/2.28 solver/libmamba conda-libmamba-solver/25.11.0 libmambapy/2.4.0
                    UID:GID : 10064:10023
                netrc file : None
            offline mode : False
    ```

There are four environments created for preprocessing and postprocessing.

1. `cawo_post`: postprocessing
2. `cdsapi`: downloading ERA5 data
3. `copernicusmarine`: downloading MERCATOR/CMEMS data
4. `loenv`: preprocessing ROMS

The modules required for each environment are stored in a `yaml` file, located in `/home/cawohdcst_ft2/yml_files`. These `yaml` files can be used for creating the intended environment if you want play around in your own computer.

??? info "Checking conda environments"
    ```bash
    (base) [cawohdcst_ft2@mdclogin1 ~]$ conda env list

    # conda environments:
    #
    # * -> active
    # + -> frozen
    base                 *   /home/cawohdcst_ft2/opt/miniforge3
    cawo_post                /home/cawohdcst_ft2/opt/miniforge3/envs/cawo_post
    cdsapi                   /home/cawohdcst_ft2/opt/miniforge3/envs/cdsapi
    copernicusmarine         /home/cawohdcst_ft2/opt/miniforge3/envs/copernicusmarine
    loenv                    /home/cawohdcst_ft2/opt/miniforge3/envs/loenv

    (base) [cawohdcst_ft2@mdclogin1 ~]$ 
    ```

### LiveOcean 

[LiveOcean(LO)](https://github.com/parkermac/LO){:target="_blank"} is used for ROMS preprocessing tool. It was customized by CLSBrasil team, so we will use the source code from `/scratch/cawohdcst_ft/home/cawohdcst/LO`. Luckily, you don't have to do that as it already exists in the `cawohdcst_ft2` home directory.

??? info "How to create LiveOcean environment?"
    In order to install this tool, we need to retrieve the source code, either from github or the one that exists in `cawohdcst_ft2` home directory. Inside the `LO` directory, there is a `yaml` file containing all modules necessary to run `lo_tools`. Hence, the way to go there is pretty simple, we only need to execute a well-known `conda` command to create environment from `yaml` file.
    ```bash
    conda create -f loenv.yml
    ```

## Preparing The Working Directory

This hands-on assume that participants logged in to MDC Supercomputer via `cawohdcst_ft2` user account. Therefore, each user must define their own working directory. 

Please create directory in the `cawohdcst_ft2` home directory using an appropriate name of your choice (not too long and without space). All downloading, preprocessing (except the LO source code) and postprocessing scripts should be stored in this directory to avoid editing the same files across different participants.
Additionally you also need to create directory in `/scratch` same as in `/home/cawohdcst_ft2` to store the data. 

### Modifying `env.sh`

It is mandatory setup our working environment using `env.sh`. Please copy the file from `/home/cawohdcst_ft2/hindcast_scripts/env.sh` to your working directory. Here is the sample.

```bash
[cawohdcst_ft2@mdclogin1 tyo]$ pwd
/home/cawohdcst_ft2/tyo
[cawohdcst_ft2@mdclogin1 tyo]$ cp /home/cawohdcst_ft2/hindcast_scripts/env.sh .
[cawohdcst_ft2@mdclogin1 tyo]$
```

Edit the `CAWO_HINDCAST_BASE` in `env.sh` file as per your `scratch` directory.

??? info "Click here to view the full script"
    ```bash title="env.sh"
    #!/bin/bash
    # 
    # Working directory
    # 
    export CAWO_HINDCAST_BASE='/scratch/cawohdcst_ft2/tyo/cawo_hindcast'
    #
    # --------------------
    # Global Data Download
    # --------------------
    export CAWO_INPUT=$CAWO_HINDCAST_BASE'/cawo_input'
    # --------------
    # Preprocessing
    # --------------
    export WPS_DIR='/scratch/cawohdcst_ft2/data/wps_run'
    export WPS_STATIC_DIR='/scratch/cawohdcst_ft/data/static/wps/wps-4.3.1_static'
    export WRF_DIR='/scratch/cawohdcst_ft/data/static/wrf'
    export WRF_STATIC_DIR=$WRF_DIR'/wrf-4.3.1_static'
    export WRF_STATIC_EXTRA_DIR=$WRF_DIR'/extra_static'
    export GEOGRID_FILE='/scratch/cawohdcst_ft/data/wps_run/geogrid_v43/geo_em.d01.nc.ID03F3'
    export GRID_DATA='/scratch/cawohdcst_ft2/data/grids'
    export ERA5_BASE_DIR=$CAWO_INPUT'/era5'
    export GLORYS_BASE_DIR=$CAWO_INPUT'/mercator'
    export ROMS_FORCING='/scratch/cawohdcst_ft2/data/roms_forcing' # tied to loenv, which defined at the conda env creation.
    # export ROMS_FORCING=$CAWO_INPUT'/roms_forcing' # ini bisa dipakai dengan mengubah Lfun dkk diimport dari utils instead dari installed lo_tools pada file driver_forcing3.py, tapi prosesnya tidak menghasilkan results.txt di LO_output, meski output data nc-ya tergenerate di folder yang didefine di line ini. 
    #
    # LiveOcean
    # export LO_Output=$DATA_DIR'/LO_output'
    # export LO_User=$DATA_DIR'/LO_output'
    #
    # -----------------
    # Model integration
    # -----------------
    export CAWO_HINDCAST_RUN=$CAWO_HINDCAST_BASE'/cawo_hindcast_run'
    # --------------
    # Postprocessing
    # --------------
    export CAWO_OUTPUT=$CAWO_HINDCAST_BASE'/cawo_output'
    ```

Then `source` it.
```bash
source env.sh
```

??? info "Click here to see the sample structure of the working directory"
    ```shell
    [cawohdcst_ft2@mdclogin1 tyo]$ pwd
    /home/cawohdcst_ft2/tyo
    [cawohdcst_ft2@mdclogin1 tyo]$ tree
    .
    ├── env.sh
    ├── mainprocess
    ├── postprocess
    └── preprocess
        ├── get_era5
        │   ├── get_era5_pl_automate.py
        │   ├── get_era5_surface_automate.py
        │   └── get_era5_waves.py
        ├── get_glorys
        │   ├── get_glorys_reanalysis_interim.py
        │   └── get_glorys_reanalysis.py
        ├── get_swan_bry
        │   ├── make_swan_bc.py
        │   └── slurm_make_swan_bc.bash
        └── wps_run
            ├── slurm_run_metgrid.bash
            ├── slurm_run_real.bash
            └── slurm_run_ungrib.bash

    7 directories, 11 files
    [cawohdcst_ft2@mdclogin1 tyo]$ mkdir /scratch/cawohdcst_ft2/tyo/
    [cawohdcst_ft2@mdclogin1 tyo]$ /scratch/cawohdcst_ft2/tyo/
    -sh: /scratch/cawohdcst_ft2/tyo/: Is a directory
    [cawohdcst_ft2@mdclogin1 tyo]$ 
    ```

## Global Reanalysis Data Acquisition

To generate all the input files that are necessary to run the hindcast, global reanalysis data that are used as initial and boundary conditions need to be downloaded to cover the total period of simulation. This procedure doesn't need to be complete before the simulations start, but needs to be always ahead in time in respect from the simulation. 

The hindcast daily cycles start at 12h00 UTC each day. This is determined by the Glorys Reanalysis time which are daily means centered at 12h UTC. Thus, to facilitate the workflow for the generation of forcing files for each day, the global models data are also downloaded for each daily cycle starting at 12h00 UTC.

### ERA5 Atmospheric Data

The ECMWF ERA5 data can be downloaded using the ECMWF Climate Data Store API (CDSAPI). The `.cdsapirc` already configured in `cawohdcst_ft2` home directory, so you don't need to worry about this.

??? info "Click to see detailed parameters"

    === "3D Data"
        Pressure levels:
        1000, 950, 925, 900, 850, 800, 700, 600, 500, 400, 300, 250, 200, 150, 100, 70, 50, 30, 20, 10, 7, 5

        | ECMWF Parameter Code | GRIB Parameter Name | Name                          | Units |
        |----------------------|---------------------|-------------------------------|-------|
        | 129                  | GH                  | Geopotential Height           | m     |
        | 130                  | TT                  | Temperature                   | K     |
        | 131                  | UU                  | U component of Wind Velocity  | m/s   |
        | 132                  | VV                  | V component of Wind Velocity  | m/s   |
        | 157                  | RH                  | Relative Humidity             | %     |

    === "2D Data"

        | ECMWF GRIB Parameter Code | Parameter Name | Name                         | Units |
        |--------------------------|--------------|------------------------------|-------|
        | 165                      | 10U          | U component of the wind velocity | m/s |
        | 166                      | 10V          | V component of the wind velocity | m/s |
        | 167                      | 2T           | 2 m Temperature              | K     |
        | 168                      | 2D           | 2 m Dewpoint Temperature     | K     |
        | 172                      | LSM          | Land-Sea Mask                | 0/1 flag |
        | 134                      | SP           | Surface Pressure             | Pa    |
        | 151                      | MSL          | Mean Sea-Level Pressure      | Pa    |
        | 235                      | SKT          | Skin Temperature             | K     |
        | 31                       | CI           | Sea Ice Fraction             | fraction |
        | 34                       | SST          | Sea Surface Temperature      | K     |
        | 33                       | RSN          | Snow Density                 | kg/m³ |
        | 141                      | SD           | Snow Depth                   | m (water equivalent) |
        | 139                      | STL1         | Soil Temperature 0–7 cm      | K     |
        | 170                      | STL2         | Soil Temperature 7–28 cm     | K     |
        | 183                      | STL3         | Soil Temperature 28–100 cm   | K     |
        | 236                      | STL4         | Soil Temperature 100–255 cm  | K     |
        | 39                       | SWVL1        | Soil Moisture 0–7 cm         | m³/m³ |
        | 40                       | SWVL2        | Soil Moisture 7–28 cm        | m³/m³ |
        | 41                       | SWVL3        | Soil Moisture 28–100 cm      | m³/m³ |
        | 42                       | SWVL4        | Soil Moisture 100–255 cm     | m³/m³ |


The required variables from ERA5 are downloaded using the ECMWF CDS api and python sripts:

- 3D data download script: `/home/cawohdcst_ft2/hindcast_scripts/preprocess/get_era5/get_era5_pl_automate.py`
- 2D data download script: `/home/cawohdcst_ft2/hindcast_scripts/preprocess/get_era5/get_era5_surface_automate.py`

Now, copy these files to your working directory. 
```bash
[cawohdcst_ft2@mdclogin1 preprocess]$ pwd
/home/cawohdcst_ft2/tyo/preprocess
[cawohdcst_ft2@mdclogin1 preprocess]$ cp -r /home/cawohdcst_ft2/hindcast_scripts/preprocess/get_era5
[cawohdcst_ft2@mdclogin1 preprocess]$ ls get_era5/ -l
total 12
-rwxr-xr-x. 1 cawohdcst_ft2 cls_ext 2697 Jan 23 07:41 get_era5_pl_automate.py
-rwxr-xr-x. 1 cawohdcst_ft2 cls_ext 2907 Jan 23 07:41 get_era5_surface_automate.py
-rwxr-xr-x. 1 cawohdcst_ft2 cls_ext 2476 Jan 23 07:41 get_era5_waves.py
[cawohdcst_ft2@mdclogin1 preprocess]$ 
```

Adjust the dates (lines 6 & 7) and `folder_name` (line 40) in both `*.py` files.

<a id="get-era5-pl-script"></a>
```py title="get_era5_pl_automate.py" hl_lines="4 5"
...
...
5 # Define the range of dates to process
6 start_date = datetime(1995, 1, 1) # Adjust this
7 end_date = datetime(1995, 1, 5)  # Adjust this, example: 2 days; adjust as needed
...
...
28 current_date = start_date
29 while current_date <= end_date:
...
...
39     # Create output directory
40     folder_name = f"/scratch/cawohdcst_ft2/tyo/data/era5/era5_{current_date.strftime('%Y%m%d')}"
41     os.makedirs(folder_name, exist_ok=True)
42 
...
...
```

The `*.grib` files are from the day represented in the folder names starting at 12h00 UTC until the next day 12h00 UTC.

??? success "Click here to view the execution log."
    === "3D Data"
        ```log 
        2026-01-23 04:34:56,410 INFO Request ID is 40f2233a-4641-4f97-b6e1-5d9dd765e82c
        2026-01-23 04:34:56,588 INFO status has been updated to accepted
        2026-01-23 04:35:10,769 INFO status has been updated to running
        2026-01-23 04:36:51,885 INFO status has been updated to successful
        Downloading /scratch/cawohdcst_ft2/tyo/data/era5/era5_19950104/part2.grib
        2026-01-23 04:37:06,470 INFO Request ID is a36f93bf-e1ea-4de4-83f9-d6f327e81dba
        2026-01-23 04:37:06,743 INFO status has been updated to accepted
        2026-01-23 04:37:15,596 INFO status has been updated to running
        2026-01-23 04:39:02,081 INFO status has been updated to successful
        Downloading /scratch/cawohdcst_ft2/tyo/data/era5/era5_19950105/part1.grib
        {'area': [15.5, 89.5, -15.5, 145.5],
        'data_format': 'grib',
        'day': '05',
        'month': '01',
        'pressure_level': ['5',
                            '7',
                            '10',
                            '20',
                            '30',
                            '50',
                            '70',
                            '100',
                            '150',
                            '200',
                            '250',
                            '300',
                            '400',
                            '500',
                            '600',
                            '700',
                            '800',
                            '850',
                            '900',
                            '925',
                            '950',
                            '1000'],
        'product_type': 'reanalysis',
        'time': ['12:00',
                '13:00',
                '14:00',
                '15:00',
                '16:00',
                '17:00',
                '18:00',
                '19:00',
                '20:00',
                '21:00',
                '22:00',
                '23:00'],
        'variable': ['geopotential',
                    'relative_humidity',
                    'temperature',
                    'u_component_of_wind',
                    'v_component_of_wind'],
        'year': '1995'}
        2026-01-23 04:39:29,148 INFO Request ID is b157c67d-319a-48a2-aaf6-af1fa1bcde60
        2026-01-23 04:39:29,343 INFO status has been updated to accepted
        2026-01-23 04:39:43,444 INFO status has been updated to running
        2026-01-23 04:41:26,402 INFO status has been updated to successful
        Downloading /scratch/cawohdcst_ft2/tyo/data/era5/era5_19950105/part2.grib
        2026-01-23 04:41:58,035 INFO Request ID is 3100a36b-00a4-448b-92f1-7cc208000079
        2026-01-23 04:41:59,125 INFO status has been updated to accepted
        2026-01-23 04:42:08,322 INFO status has been updated to running
        2026-01-23 04:43:54,771 INFO status has been updated to successful
        (cdsapi) sh-4.4$ 
        ```
    === "2D Data"
        ```log
        2026-01-23 04:32:24,221 INFO [2025-12-11T00:00:00] Please note that a dedicated catalogue entry for this dataset, post-processed and stored in Analysis Ready Cloud Optimized (ARCO) format (Zarr), is available for optimised time-series retrievals (i.e. for retrieving data from selected variables for a single point over an extended period of time in an efficient way). You can discover it [here](https://cds.climate.copernicus.eu/datasets/reanalysis-era5-single-levels-timeseries?tab=overview)
        2026-01-23 04:32:24,222 INFO Request ID is 13419524-b9d9-44e3-9f26-c285af4b614d
        2026-01-23 04:32:24,435 INFO status has been updated to accepted
        2026-01-23 04:34:19,878 INFO status has been updated to running
        2026-01-23 04:35:18,519 INFO status has been updated to successful
        Downloading /scratch/cawohdcst_ft2/tyo/data/era5/era5_19950105/part1.grib
        {'area': [15.5, 89.5, -15.5, 145.5],
        'data_format': 'grib',
        'day': '05',
        'month': '01',
        'product_type': 'reanalysis',
        'time': ['12:00',
                '13:00',
                '14:00',
                '15:00',
                '16:00',
                '17:00',
                '18:00',
                '19:00',
                '20:00',
                '21:00',
                '22:00',
                '23:00'],
        'variable': ['10m_u_component_of_wind',
                    '10m_v_component_of_wind',
                    '2m_dewpoint_temperature',
                    '2m_temperature',
                    'mean_sea_level_pressure',
                    'sea_surface_temperature',
                    'surface_pressure',
                    'skin_temperature',
                    'snow_density',
                    'snow_depth',
                    'soil_temperature_level_1',
                    'soil_temperature_level_2',
                    'soil_temperature_level_3',
                    'soil_temperature_level_4',
                    'volumetric_soil_water_layer_1',
                    'volumetric_soil_water_layer_2',
                    'volumetric_soil_water_layer_3',
                    'volumetric_soil_water_layer_4',
                    'land_sea_mask',
                    'sea_ice_cover'],
        'year': '1995'}
        2026-01-23 04:35:27,043 INFO [2025-12-11T00:00:00] Please note that a dedicated catalogue entry for this dataset, post-processed and stored in Analysis Ready Cloud Optimized (ARCO) format (Zarr), is available for optimised time-series retrievals (i.e. for retrieving data from selected variables for a single point over an extended period of time in an efficient way). You can discover it [here](https://cds.climate.copernicus.eu/datasets/reanalysis-era5-single-levels-timeseries?tab=overview)
        2026-01-23 04:35:27,043 INFO Request ID is cd9fb5f3-f0f3-4250-bf0f-b5bd34000543
        2026-01-23 04:35:27,242 INFO status has been updated to accepted
        2026-01-23 04:36:43,896 INFO status has been updated to running
        2026-01-23 04:37:24,808 INFO status has been updated to successful
        Downloading /scratch/cawohdcst_ft2/tyo/data/era5/era5_19950105/part2.grib
        2026-01-23 04:37:31,744 INFO [2025-12-11T00:00:00] Please note that a dedicated catalogue entry for this dataset, post-processed and stored in Analysis Ready Cloud Optimized (ARCO) format (Zarr), is available for optimised time-series retrievals (i.e. for retrieving data from selected variables for a single point over an extended period of time in an efficient way). You can discover it [here](https://cds.climate.copernicus.eu/datasets/reanalysis-era5-single-levels-timeseries?tab=overview)
        2026-01-23 04:37:31,744 INFO Request ID is 6b0e3600-79b6-48aa-9f7f-f4bad9f0e8b9
        2026-01-23 04:37:31,929 INFO status has been updated to accepted
        2026-01-23 04:38:48,581 INFO status has been updated to running
        2026-01-23 04:39:27,245 INFO status has been updated to successful
        (cdsapi) [cawohdcst_ft2@mdclogin1 preprocess]$
        ```

### ERA5 Waves Data

From the ERA5, the following variables are used as SWAN boundary conditions and need to be downloaded:

- `significant_height_of_combined_wind_waves_and_swell`;
- `mean_wave_period`;
- `mean_wave_direction`;

The data from ERA5 are downloaded using the ECMWF CDS api and python script. The script is located in `/home/cawohdcst_ft2/hindcast_scripts/preprocess/get_era5/get_era5_waves.py`. It should already placed in your working directory as we perform recursive copy in the ERA5 Atmosphere.

Similar with the previous script ([Code block 1](#get-era5-pl-script)), adjust the dates by replacing the value of variables `start_date` and `end_date` to specify the downloading period, as well as the `folder_name`. 

The `*.grib` files are from the day represented in the folder names starting at 12h00 UTC until the next day 12h00 UTC.


??? success "Click here to view the execution log."
    ```log 
    2026-01-23 04:37:29,540 INFO [2025-12-11T00:00:00] Please note that a dedicated catalogue entry for this dataset, post-processed and stored in Analysis Ready Cloud Optimized (ARCO) format (Zarr), is available for optimised time-series retrievals (i.e. for retrieving data from selected variables for a single point over an extended period of time in an efficient way). You can discover it [here](https://cds.climate.copernicus.eu/datasets/reanalysis-era5-single-levels-timeseries?tab=overview)
    2026-01-23 04:37:29,541 INFO Request ID is 99f6fc34-1490-42d8-b873-00b15a9ddfed
    2026-01-23 04:37:29,726 INFO status has been updated to accepted
    2026-01-23 04:38:46,438 INFO status has been updated to successful
    Downloading /scratch/cawohdcst_ft2/tyo/data/era5_waves/era5_19950105/part1.grib
    {'area': [15.5, 89.5, -15.5, 145.5],
    'data_format': 'grib',
    'day': '05',
    'month': '01',
    'product_type': 'reanalysis',
    'time': ['12:00',
            '13:00',
            '14:00',
            '15:00',
            '16:00',
            '17:00',
            '18:00',
            '19:00',
            '20:00',
            '21:00',
            '22:00',
            '23:00'],
    'variable': ['significant_height_of_combined_wind_waves_and_swell',
                'mean_wave_period',
                'mean_wave_direction',
                'wave_spectral_directional_width'],
    'year': '1995'}
    2026-01-23 04:38:49,652 INFO [2025-12-11T00:00:00] Please note that a dedicated catalogue entry for this dataset, post-processed and stored in Analysis Ready Cloud Optimized (ARCO) format (Zarr), is available for optimised time-series retrievals (i.e. for retrieving data from selected variables for a single point over an extended period of time in an efficient way). You can discover it [here](https://cds.climate.copernicus.eu/datasets/reanalysis-era5-single-levels-timeseries?tab=overview)
    2026-01-23 04:38:49,653 INFO Request ID is 8ba0c4a6-cd59-4f12-a2cd-c0496bb938b8
    2026-01-23 04:38:49,839 INFO status has been updated to accepted
    2026-01-23 04:39:23,434 INFO status has been updated to running
    2026-01-23 04:39:40,736 INFO status has been updated to successful
    Downloading /scratch/cawohdcst_ft2/tyo/data/era5_waves/era5_19950105/part2.grib
    2026-01-23 04:39:43,730 INFO [2025-12-11T00:00:00] Please note that a dedicated catalogue entry for this dataset, post-processed and stored in Analysis Ready Cloud Optimized (ARCO) format (Zarr), is available for optimised time-series retrievals (i.e. for retrieving data from selected variables for a single point over an extended period of time in an efficient way). You can discover it [here](https://cds.climate.copernicus.eu/datasets/reanalysis-era5-single-levels-timeseries?tab=overview)
    2026-01-23 04:39:43,730 INFO Request ID is e2bf8015-d921-4474-bde4-f6449f5e3381
    2026-01-23 04:39:43,916 INFO status has been updated to accepted
    2026-01-23 04:41:01,360 INFO status has been updated to running
    2026-01-23 04:41:40,172 INFO status has been updated to successful
    (cdsapi) sh-4.4$ 
    ```


### Mercator GLORYS12V1 Data

From the Mercator Reanalysis GLORYS12V1 the following variables are used as ROMS initial, boundary conditions and climatology files and need to be downloaded:

- `uo` – Eastward current velocities;
- `vo` – Northward current valocities;
- `thetao` – Sea water potential temperature;
- `so` – Sea water salinity;
- `zos` – Sea surface height above geoid;

Data from GLORYS12V1 are downloaded using copernicusmarine api and python sripts.
Data download scripts: 

- `/home/cawohdcst_ft2/hindcast_scripts/preprocess/get_glorys/get_glorys_reanalysis.py` (1995 - 2021)
- `/home/cawohdcst_ft2/hindcast_scripts/preprocess/get_glorys/get_glorys_reanalysis_interim.py` (2021 - 2024)

Copy those scripts to your working directory.
```bash
[cawohdcst_ft2@mdclogin1 preprocess]$ pwd
/home/cawohdcst_ft2/tyo/preprocess
[cawohdcst_ft2@mdclogin1 preprocess]$ cp -r /home/cawohdcst_ft2/hindcast_scripts/preprocess/get_glorys
[cawohdcst_ft2@mdclogin1 preprocess]$ ls get_glorys/ -l
total 8
-rwxr-xr-x. 1 cawohdcst_ft2 cls_ext 1277 Jan 23 07:41 get_glorys_reanalysis_interim.py
-rwxr-xr-x. 1 cawohdcst_ft2 cls_ext 1274 Jan 23 07:41 get_glorys_reanalysis.py
[cawohdcst_ft2@mdclogin1 preprocess]$ 
```

 Similar with the previous script ([Code block 1](#get-era5-pl-script)), adjust the dates by replacing the value of variables `start_date` and `end_date` to specify the downloading period, as well as the `output_directory`. 

The daily GLORYS12V1 files are placed on: `/scratch/<your_user_name>/<your_name>/data/mercator/GLORYS_Reanalysis_LO_YYYY-MM-DDT00:00:00.nc`, or in this case our username is `cawohdcst_ft2`.

??? success "Click here to view the execution log."
    ```log 
    INFO - 2026-01-23T04:35:10Z - Selected dataset version: "202311"
    INFO - 2026-01-23T04:35:10Z - Selected dataset part: "default"
    WARNING - 2026-01-23T04:35:10Z - Some of your subset selection [0.494, 5727.9169921875] for the depth dimension exceed the dataset coordinates [0.49402499198913574, 5727.9169921875]
    INFO - 2026-01-23T04:35:18Z - Starting download. Please wait...
    100%|██| 74/74 [00:19<00:00,  3.74it/s]
    INFO - 2026-01-23T04:35:40Z - Successfully downloaded to /scratch/cawohdcst_ft2/tyo/data/mercator/GLORYS_Reanalysis_LO_1995-01-04T00:00:00.nc
    WARNING - 2026-01-23T04:35:40Z - 'force_download' has been deprecated.
    INFO - 2026-01-23T04:35:44Z - Selected dataset version: "202311"
    INFO - 2026-01-23T04:35:44Z - Selected dataset part: "default"
    WARNING - 2026-01-23T04:35:44Z - Some of your subset selection [0.494, 5727.9169921875] for the depth dimension exceed the dataset coordinates [0.49402499198913574, 5727.9169921875]
    INFO - 2026-01-23T04:35:52Z - Starting download. Please wait...
    100%|██| 74/74 [00:19<00:00,  3.83it/s]
    INFO - 2026-01-23T04:36:13Z - Successfully downloaded to /scratch/cawohdcst_ft2/tyo/data/mercator/GLORYS_Reanalysis_LO_1995-01-05T00:00:00.nc
    ```

## Pre Processing
After acquiring the global reanalysis data, it must be converted into the formats required by ROMS, SWAN, and WRF. The following sections describe the steps involved in transforming the data, as well as the locations of the scripts used in each stage. Once the pre-processing is complete, the data are properly formatted and ready to be consumed by the models.

### WRF Forcing Files
The regional atmospheric model WRF forcing files are generated using the WRF Preprocessing System ([WPS](https://www2.mmm.ucar.edu/wrf/users/wrf_users_guide/build/html/wps.html){:target="_blank"}) which is already installed on the HPC.

After the ERA5 surface and pressure levels `.grib` files are downloaded for a given day, three sequential steps should be followed to generate the WRF file for that specific day:

- Run ungrib - `/home/cawohdcst_ft2/hindcast_scripts/preprocess/wps_run/slurm_run_ungrib.bash`
- Run metgrid - `/home/cawohdcst_ft2/hindcast_scripts/preprocess/wps_run/slurm_run_ungrib.bash`
- Run real - `/home/cawohdcst_ft2/hindcast_scripts/preprocess/wps_run/slurm_run_real.bash`

Now, copy these files to your working directory. 
```bash
[cawohdcst_ft2@mdclogin1 preprocess]$ pwd
/home/cawohdcst_ft2/tyo/preprocess
[cawohdcst_ft2@mdclogin1 preprocess]$ cp -r /home/cawohdcst_ft2/hindcast_scripts/preprocess/wps_run
[cawohdcst_ft2@mdclogin1 preprocess]$ ls wps_run/ -l
total 12
-rwxr-xr-x. 1 cawohdcst_ft2 cls_ext 2876 Jan 23 07:13 slurm_run_metgrid.bash
-rwxr-xr-x. 1 cawohdcst_ft2 cls_ext 2892 Jan 23 07:13 slurm_run_real.bash
-rwxr-xr-x. 1 cawohdcst_ft2 cls_ext 2793 Jan 23 07:56 slurm_run_ungrib.bash
[cawohdcst_ft2@mdclogin1 preprocess]$ 
```
The codes should be run in sequence (step 1 – run ungrib, step 2 – run metgrid, step 3 – run real) for the dates you want to generate the forcing files.*

Then run the slurm scripts with:
```bash
sbatch slurm_run_ungrib.bash #(once completed, go to the next)
sbatch slurm_run_metgrid.bash #(once completed, go to the next)
sbatch slurm_run_real.bash #(once completed, WRF forcing file are generated)
```

??? success "Click here to view the execution log."
    === "Ungrib"
        ```log title="run_ungrib_loop_<jobid>.log"
        ...
        ...
        !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
        !  Successful completion of ungrib.   !
        !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
        Reading from FILE at time 1995-01-05_12
        Reading from FILE at time 1995-01-05_15
        Reading from FILE at time 1995-01-05_18
        Reading from FILE at time 1995-01-05_21
        Reading from FILE at time 1995-01-06_00
        Reading from FILE at time 1995-01-06_03
        Reading from FILE at time 1995-01-06_06
        Reading from FILE at time 1995-01-06_09
        *** Successful completion of program avg_tsfc.exe ***
        ```
    === "Metgrid"
        ```log title="run_metgrid_loop_<jobid>.log"
        + mpiexec.hydra -bootstrap slurm -n 128 -ppn 32 ./metgrid.exe
        Processing domain 1 of 1
            ./TAVGSFC
        Processing 1995-01-05_12
            FILE_PL
            FILE_SFC
        Processing 1995-01-05_15
            FILE_PL
            FILE_SFC
        Processing 1995-01-05_18
            FILE_PL
            FILE_SFC
        Processing 1995-01-05_21
            FILE_PL
            FILE_SFC
        Processing 1995-01-06_00
            FILE_PL
            FILE_SFC
        Processing 1995-01-06_03
            FILE_PL
            FILE_SFC
        Processing 1995-01-06_06
            FILE_PL
            FILE_SFC
        Processing 1995-01-06_09
            FILE_PL
            FILE_SFC
        Processing 1995-01-06_12
            FILE_PL
            FILE_SFC
        !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
        !  Successful completion of metgrid.  !
        !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

        real	2m57.264s
        user	0m0.012s
        sys	0m0.040s
        ++ date -d '19950105 +1 day' +%Y%m%d
        + current_date=19950106
        + [[ 19950106 -le 19950105 ]]
        ```
    === "Real"
        ```log title="run_real_loop_<jobid>.log"
        starting wrf task          256  of          512
        starting wrf task          266  of          512
        starting wrf task          269  of          512
        starting wrf task          383  of          512
        starting wrf task          265  of          512
        starting wrf task          270  of          512
        starting wrf task          377  of          512
        starting wrf task          352  of          512
        starting wrf task          261  of          512
        starting wrf task          358  of          512
        starting wrf task          373  of          512
        starting wrf task          374  of          512
        starting wrf task          263  of          512
        starting wrf task          371  of          512
        starting wrf task          375  of          512
        starting wrf task          380  of          512
        starting wrf task          304  of          512
        starting wrf task          317  of          512
        starting wrf task          318  of          512

        real	4m53.225s
        user	0m0.013s
        sys	0m0.041s
        ++ date -d '19950105 +1 day' +%Y%m%d
        + current_date=19950106
        + [[ 19950106 -le 19950105 ]]
        ```
### SWAN Forcing Files
After the ERA5 waves `*.grib` files are downloaded for a desired range of dates the follow script should be edit to generate the SWAN boundary condition files:
`/home/cawohdcst_ft2/hindcast_scripts/preprocess/get_swan_bry/make_swan_bc.py` and `/home/cawohdcst_ft2/hindcast_scripts/preprocess/get_swan_bry/slurm_make_swan_bc.bash`

Don't forget to copy this file to your working directory, 
```bash
[cawohdcst_ft2@mdclogin1 preprocess]$ pwd
/home/cawohdcst_ft2/tyo/preprocess
[cawohdcst_ft2@mdclogin1 preprocess]$ cp -r /home/cawohdcst_ft2/hindcast_scripts/preprocess/get_swan_bry
[cawohdcst_ft2@mdclogin1 preprocess]$ ls get_swan_bry/ -l
total 8
-rwxr-xr-x. 1 cawohdcst_ft2 cls_ext 2874 Jan 23 07:41 make_swan_bc.py
-rwxr-xr-x. 1 cawohdcst_ft2 cls_ext  279 Jan 23 07:41 slurm_make_swan_bc.bash
[cawohdcst_ft2@mdclogin1 preprocess]$ 
```
and modify the following:
```python title="make_swan_bc.py" hl_lines="4 5 12 13"
...
...
68 if __name__ == "__main__":
69     start_str = "1995-01-01" # Modify this
70     end_str = "1995-01-06"   # Modify this
71     start_date = datetime.strptime(start_str, "%Y-%m-%d")
72     end_date = datetime.strptime(end_str, "%Y-%m-%d")
...
...
```

Then run with the slurm script:
```bash
sbatch slurm_make_swan_bc.bash
```

??? success "Click here to view the execution log."
    ```log title="run_swan_bc_<jobid>.log"
    ...
    ...
    ✅ Processed era5_19950101
    ✅ Processed era5_19950102
    ✅ Processed era5_19950103
    ✅ Processed era5_19950104
    ✅ Processed era5_19950105
    ```
    
### ROMS Forcing Files

GLORYS12V1 daily data are preprocessed using modified scripts from the [LiveOcean python toolbox](https://github.com/parkermac/LO). The toolbox is a set of tools developed for a forecast system in the US northwest coast.

The LO pre-processing scripts are designed to generate ROMS forcing files from HYCOM forecast outputs. The scripts to generate ROMS initial conditions files were adapted to use GLORYS12V1 data and interpolation methods were also modified, changing the nearest neighbor interpolations on both horizontal and vertical to linear interpolation.

The modified scripts are under the folder `/home/cawohdcst_ft2/hindcast_scripts/preprocess/LO_user`. Copy this directory to your working directory.
```bash
[cawohdcst_ft2@mdclogin1 preprocess]$ pwd
/home/cawohdcst_ft2/tyo/preprocess
[cawohdcst_ft2@mdclogin1 preprocess]$ cp -r /home/cawohdcst_ft2/hindcast_scripts/preprocess/LO_user .
[cawohdcst_ft2@mdclogin1 preprocess]$ ls LO_user/ -l
total 28
drwxr-xr-x.  5 cawohdcst_ft2 cls_ext 4096 Jan 23 09:01 driver
drwxr-xr-x. 11 cawohdcst_ft2 cls_ext 4096 Jan 23 08:49 extract
drwxr-xr-x.  4 cawohdcst_ft2 cls_ext 4096 Jan 23 08:49 forcing
-rwxr-xr-x.  1 cawohdcst_ft2 cls_ext 3564 Jan 23 08:58 get_lo_info.py
drwxr-xr-x.  3 cawohdcst_ft2 cls_ext 4096 Jan 23 08:49 lo_tools
drwxr-xr-x.  3 cawohdcst_ft2 cls_ext 4096 Jan 23 08:49 pgrid
drwxr-xr-x.  2 cawohdcst_ft2 cls_ext 4096 Jan 23 08:49 __pycache__
[cawohdcst_ft2@mdclogin1 preprocess]$ 
```

#### 1 Generate templates for ic/bc

Generate template files for the hindcast using `/home/cawohdcst_ft2/tyo/preprocess/get_roms_icbc/slurm_run_ocnA0_wrap.bash`. Adjust the `date` as needed (see the hightlighted lines).

??? info "Click here to see the script"
    ```bash title="slurm_run_ocnA0_wrap.bash" linenums="1" hl_lines="18 23 24" 
    #!/bin/bash
    #SBATCH --job-name=forcing_parallel
    #SBATCH --nodes=1
    #SBATCH --ntasks=1
    #SBATCH --cpus-per-task=4     # number of parallel jobs allowed
    #SBATCH --time=01:00:00
    #SBATCH --partition=HDCAST
    #SBATCH --output=forcing_parallel_%j.out

    source ~/.bashrc
    source /home/cawohdcst_ft2/opt/miniforge3/etc/profile.d/conda.sh
    conda activate loenv

    # =========================
    # INIT DAY (new)
    # =========================
    echo "Running initialization day"
    python driver_forcing3.py -g cawo -0 "1995.01.01" -s "new" -f ocnA0

    # =========================
    # DATE RANGE
    # =========================
    start_date="1995-01-02"
    end_date="1995-01-05"
    current_date="$start_date"
    MAX_PARALLEL=16   # limit parallel processes
    job_count=0
    echo "Launching parallel forcing jobs..."
    while [[ "$(date -d "$current_date" +%s)" -le "$(date -d "$end_date" +%s)" ]]
    do
        formatted_date=$(date -d "$current_date" +%Y.%m.%d)
        echo "Launching forcing for $formatted_date"
        python driver_forcing3.py -g cawo -0 "$formatted_date" -f ocnA0 &
        ((job_count++))
        # limit parallel jobs
        if (( job_count >= MAX_PARALLEL )); then
            wait   # wait for all background jobs
            job_count=0
        fi
        current_date=$(date -d "$current_date + 1 day" +%Y-%m-%d)
    done
    # wait for remaining jobs
    wait
    echo "All forcing jobs completed."
    ```

Launch the script.
```bash
sbatch slurm_run_ocnA0_wrap.bash
```

The script generates ic/bc for ROMS stored in the following directory pattern `/scratch/cawohdcst_ft2/data/roms_forcing/fYYYYMMDD/ocnA0/`. Noted that the day 1 also consists `ocean_ini.nc` file as an initial conditions.
```bash
[cawohdcst_ft2@mdclogin1 get_roms_icbc]$ ls /scratch/cawohdcst_ft2/data/roms_forcing/f19950101/ocnA0/ -lth
total 252M
-rw-r--r--. 1 cawohdcst_ft2 cls_ext 262K Jan 23 16:01 ocean_bry.nc
-rw-r--r--. 1 cawohdcst_ft2 cls_ext 126M Jan 23 16:01 ocean_ini.nc
-rw-r--r--. 1 cawohdcst_ft2 cls_ext 126M Jan 23 16:00 ocean_clm.nc
drwxrwxr-x. 2 cawohdcst_ft2 cls_ext 4.0K Dec 15 19:22 Data
drwxrwxr-x. 2 cawohdcst_ft2 cls_ext 4.0K Dec 15 19:22 Info
(loenv) [cawohdcst_ft2@mdclogin1 get_roms_icbc]$ ls /scratch/cawohdcst_ft2/data/roms_forcing/f19950102/ocnA0/ -lth
total 126M
-rw-r--r--. 1 cawohdcst_ft2 cls_ext 262K Jan 23 16:02 ocean_bry.nc
-rw-r--r--. 1 cawohdcst_ft2 cls_ext 126M Jan 23 16:02 ocean_clm.nc
drwxr-xr-x. 2 cawohdcst_ft2 cls_ext 4.0K Dec 16 13:29 Data
drwxr-xr-x. 2 cawohdcst_ft2 cls_ext 4.0K Dec 16 13:29 Info
```
??? success "Click here to view the execution log."
    ```log title="log_ocnA0_<jobid>.log"
    Running initialization day
    dt0, dt1 1995-01-01 00:00:00 1995-01-01 00:00:00
    ------Forcing: ocnA0, backfill, 1995.01.01-1995.01.01 ------
    * frc=ocnA0, day=1995.01.01, result=success, note=NONE
    start=2026.01.23 10:30:23 (took 360 sec)
    /home/cawohdcst_ft2/LO_output/forcing/cawo/f1995.01.01/ocnA0

    Launching parallel forcing jobs...
    Launching forcing for 1995.01.02
    Launching forcing for 1995.01.03
    Launching forcing for 1995.01.04
    Launching forcing for 1995.01.05
    dt0, dt1 1995-01-03 00:00:00 1995-01-03 00:00:00
    ------Forcing: ocnA0, backfill, 1995.01.03-1995.01.03 ------
    * frc=ocnA0, day=1995.01.03, result=success, note=NONE
    start=2026.01.23 10:36:30 (took 129 sec)
    /home/cawohdcst_ft2/LO_output/forcing/cawo/f1995.01.03/ocnA0

    dt0, dt1 1995-01-05 00:00:00 1995-01-05 00:00:00
    ------Forcing: ocnA0, backfill, 1995.01.05-1995.01.05 ------
    * frc=ocnA0, day=1995.01.05, result=success, note=NONE
    start=2026.01.23 10:36:30 (took 130 sec)
    /home/cawohdcst_ft2/LO_output/forcing/cawo/f1995.01.05/ocnA0

    dt0, dt1 1995-01-02 00:00:00 1995-01-02 00:00:00
    ------Forcing: ocnA0, backfill, 1995.01.02-1995.01.02 ------
    * frc=ocnA0, day=1995.01.02, result=success, note=NONE
    start=2026.01.23 10:36:30 (took 130 sec)
    /home/cawohdcst_ft2/LO_output/forcing/cawo/f1995.01.02/ocnA0

    dt0, dt1 1995-01-04 00:00:00 1995-01-04 00:00:00
    ------Forcing: ocnA0, backfill, 1995.01.04-1995.01.04 ------
    * frc=ocnA0, day=1995.01.04, result=success, note=NONE
    start=2026.01.23 10:36:30 (took 131 sec)
    /home/cawohdcst_ft2/LO_output/forcing/cawo/f1995.01.04/ocnA0

    All forcing jobs completed.

    ```

#### 2 Populate templates for ic/bc

`/home/cawohdcst_ft2/tyo/preprocess/get_roms_icbc/slurm_run_ocnGcawo_parallel_v3.bash` – driver script for generating the ROMS forcing files;

Launch the script.
```bash
sbatch slurm_run_ocnGcawo_parallel_v3.bash
```
```bash
[cawohdcst_ft2@mdclogin1 get_roms_icbc]$ ls /scratch/cawohdcst_ft2/data/roms_forcing/f19950101/ocnG/ -lth
total 6.3G
-rwxrwxr-x. 1 cawohdcst_ft2 cls_ext 8.8M Jan 23 16:53 ocean_bry.nc
-rwxrwxr-x. 1 cawohdcst_ft2 cls_ext 3.2G Jan 23 16:53 ocean_clm.nc
-rwxrwxr-x. 1 cawohdcst_ft2 cls_ext 3.2G Dec 16 09:04 ocean_ini.nc
[cawohdcst_ft2@mdclogin1 get_roms_icbc]$ ls /scratch/cawohdcst_ft2/data/roms_forcing/f19950102/ocnG/ -lth
total 3.2G
-rw-r--r--. 1 cawohdcst_ft2 cls_ext 8.8M Jan 23 16:53 ocean_bry.nc
-rw-r--r--. 1 cawohdcst_ft2 cls_ext 3.2G Jan 23 16:53 ocean_clm.nc
[cawohdcst_ft2@mdclogin1 get_roms_icbc]$ 
```
??? success "Click here to view the execution log."
    ```log
    ...
    ...
    ...
    47
    48
    49
    Vertical interpolation
    Vertical interpolation
    Vertical interpolation
    Vertical interpolation
    Finished 1995-01-01
    ```

## Running the Hindcast

Once the data are properly pre-processed for the selected period, we are ready to run the hindcast. This section describes the steps required to compile the model, prepare the input folders (grid, configuration files, and forcing files), and set up the output directories. After completing these steps, the model can be executed and the results will be available for the post-processing stage.

### Compiling COAWST

The model code used to run the hindcast is placed at:

- `/home/cawohdcst_ft2/models/cawo_3way_swell_mods_ramp_tides/` for day 1 
- `/home/cawohdcst_ft2/models/cawo_3way_swell_mods_no_ramp_tides/` for after day 1

There are some varibles need to be changed related to the path inside `coawst.bash`. Additionally, the different configurations on the ramp tides usage is adjusted in the `Projects/CAWO_3way/cawo_3way.h`. But, in this case, you don't need to worry as it has been done during the FT. So, all you need to do is to compile the Coawst model for each scenario to get the binary `coawstM`. Here is the command to compile the model.

```bash
sbatch slurm_compile_cawo.bash
```

### Running Scheme

The runs are being conducted at your designed directory which defined in `env.sh`. In this example, they're located at `/scratch/cawohdcst_ft2/tyo/cawo_hindcast/cawo_hindcast_run` and its outputs are directed to `/scratch/cawohdcst_ft2/tyo/cawo_hindcast/cawo_output`. 

However, the working directory where we launch the source code still from `home` directory, e.g. `/home/cawohdcst_ft2/tyo/hindcast_run`. The `scratch` folder is used for I/O purposes.

The hindcast is run in separate daily cycles. A folder for each cycle should be created by using the follwing script:
```bash
python create_folders.py
```

### Modifying Namelist Files

The following scripts will modify the namelist files required by the three models according to each daily cycle/run directory. To modify the namelist files according to the respective days run:

Modifying day1
```bash
(base) sh-4.4$ python modify_dot_in.py 19950101  19950101 --day1
Start date: 19950101
End date  : 19950101
Day1 mode : True
Models   : roms, swan, wrf
--------------------------------------------------
=== Modifying ROMS input files ===
=== Modifying SWAN input files ===
=== Modifying WRF input files ===

All .in files updated successfully.
```

Non day1
```bash
(base) sh-4.4$ python modify_dot_in.py 19950102 19950105
Start date: 19950102
End date  : 19950105
Day1 mode : False
Models   : roms, swan, wrf
--------------------------------------------------
=== Modifying ROMS input files ===
=== Modifying SWAN input files ===
=== Modifying WRF input files ===

All .in files updated successfully.
```

### Copying input files

The following script will copy the files that are needed into the daily run directories. These files include the WRF forcing files generated with WPS, coawstM executable, slurm script and others. 

```bash
./copy_files_for_run_day1.bash # for day1
./copy_files_for_run.bash # after day1
```

### Running a day cycle

The hindcast is designed to run in daily cycles, at first it is recommended that at least two or three days be run individually. This helps the user to better understand the sequence before launching the automation script. 
Enter your `scratch` directory for the day you want to run and run the following slurm script:

```bash
sbatch slurm_run_cawo_3way_hdcst.bash
```

### Running automation

As the 30 years hindcast is split into daily cycles, a driver script was designed to launch the sequential daily runs one after another. The bash script goes from a given start day to an end day. As a daily cycle is complete, the script advances to the next day and continues to do it until the final day is reached.
To automatically run a sequence of days, run the following:

```bash
nohup ./run_hindcast.bash &> log/log_run.log &
```

## Post Processing

The raw outputs from WRF (surface and pressure levels) and ROMS/SWAN should be postprocessed to meet the clients requirements. The data needs to be CF compliant and store only the variables needed for surface (WRF 2D), pressure levels (WRF 3D), surface (ocean 2D), and z levels (ocean 3D).

### WRF2D

The raw outputs from WRF are remapped to the required regularly spaced latitude and longitude grid using the [`xesmf` toolbox](https://xesmf.readthedocs.io/en/stable/).
The /home/cawohdcst/postprocess directory should be mirrored on your home directory:

```bash
cp –r /scratch/cawohdcst_ft/home/cawohdcst/postprocess ~/
```

Then edit and run the script below:
```bash
sbatch ~/postprocess/slurm_run_post_wrf2d.bash
```

*Remember to adjust the paths related to your user and to choose the start and end dates for postprocessing.
The postprocessed files will be placed on:
`/scratch/<your_user_name>/data/postprocessed/wrf2d/fyyyymmdd`

### WRF3D

Similarly to the WRF 2D, run the script bellow:

```bash
sbatch ~/postprocess/slurm_run_post_wrf3d.bash
```

The postprocessed files will be placed on:
`/scratch/<your_user_name>/data/postprocessed/wrf3d/fyyyymmdd`

### Ocean2D

Run: 
```bash
sbatch ~/postprocess/slurm_run_post_ocean2d.bash
```
The postprocessed files will be placed on:
`/scratch/<your_user_name>/data/postprocessed/ocean2d/fyyyymmdd`

### Ocean3D

Additionally to the `xesmf` remapping, the sigma layer outputs should be converted to z levels. For that task, the [`xroms` package](https://xroms.readthedocs.io/en/latest/) is used.
Run: 
```bash
sbatch ~/postprocess/slurm_run_post_ocean3d.bash
```
The postprocessed files will be placed on:
`/scratch/<your_user_name>/data/postprocessed/ocean3d/fyyyymmdd`        

## Summary and Common Problems

*work in progres*