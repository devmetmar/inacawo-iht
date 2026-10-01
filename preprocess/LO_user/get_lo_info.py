"""
Path structure for LiveOcean used by InaCAWO hindcast preprocessing.

Ldir is filled here and extended by Lfun for each model run.

Layout (portable — no hardcoded username):
  $HOME/inacawo-deps/LO                              code (conda editable lo_tools)
  $HOME/inacawo-iht/preprocess/LO_user               this file + user overrides
  /scratch/$USER/inacawo-iht/cawo_input/LO_data      static / input data
  /scratch/$USER/inacawo-iht/cawo_input/LO_output    forcing and LO runtime output
"""
import os
from pathlib import Path

HOME = Path.home()
USER = os.environ.get('USER') or HOME.name
SCRATCH = Path('/scratch') / USER
CAWO_INPUT = SCRATCH / 'inacawo-iht' / 'cawo_input'

# InaCAWO split layout — prefer env SST (setup_env.bash / inacawo-deps/env)
LO = Path(os.environ.get('LO', HOME / 'inacawo-deps' / 'LO'))
LOu = Path(os.environ.get('LO_USER', HOME / 'inacawo-iht' / 'preprocess' / 'LO_user'))
data = Path(os.environ.get('LO_DATA', CAWO_INPUT / 'LO_data'))
LOo = Path(os.environ.get('LO_OUTPUT', CAWO_INPUT / 'LO_output'))

# Generic parent used by some LO helpers (not used for data/output above)
parent = HOME

# Obsolete for current InaCAWO builds; kept for LO API compatibility
roms_code = parent / 'LiveOcean_roms'
traps_name = 'traps00'

roms_out = Path(os.environ.get('LO_ROMS', CAWO_INPUT / 'LO_roms'))
roms_out1 = parent / 'BLANK'
roms_out2 = parent / 'BLANK'
roms_out3 = parent / 'BLANK'
roms_out4 = parent / 'BLANK'

remote_user = 'BLANK'
remote_machine = 'BLANK'
remote_dir0 = 'BLANK'
local_user = 'BLANK'

which_matlab = '/usr/local/bin/matlab'
lo_env = 'inacawo'

try:
    HOSTNAME = os.environ['HOSTNAME']
except KeyError:
    HOSTNAME = 'BLANK'

Ldir0 = dict()
Ldir0['lo_env'] = lo_env
Ldir0['parent'] = parent
Ldir0['LO'] = LO
Ldir0['LOo'] = LOo
Ldir0['LOu'] = LOu
Ldir0['data'] = data
Ldir0['roms_code'] = roms_code
Ldir0['roms_out'] = roms_out
Ldir0['roms_out1'] = roms_out1
Ldir0['roms_out2'] = roms_out2
Ldir0['roms_out3'] = roms_out3
Ldir0['roms_out4'] = roms_out4
Ldir0['which_matlab'] = which_matlab
Ldir0['remote_user'] = remote_user
Ldir0['remote_machine'] = remote_machine
Ldir0['remote_dir0'] = remote_dir0
Ldir0['local_user'] = local_user
Ldir0['traps_name'] = traps_name
