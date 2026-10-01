"""
Path structure for LiveOcean used by get_roms_icbc utils.

Same portable layout as preprocess/LO_user/get_lo_info.py:
  $HOME/inacawo-deps/LO
  $HOME/inacawo-iht/preprocess/LO_user
  /scratch/$USER/LO_data
  /scratch/$USER/LO_output
"""
import os
from pathlib import Path

HOME = Path.home()
USER = os.environ.get('USER') or HOME.name
SCRATCH = Path('/scratch') / USER

LO = Path(os.environ.get('LO', HOME / 'inacawo-deps' / 'LO'))
LOu = Path(os.environ.get('LO_USER', HOME / 'inacawo-iht' / 'preprocess' / 'LO_user'))
data = Path(os.environ.get('LO_DATA', SCRATCH / 'LO_data'))
LOo = Path(os.environ.get('LO_OUTPUT', SCRATCH / 'LO_output'))
parent = HOME

roms_code = parent / 'LiveOcean_roms'
traps_name = 'traps00'

roms_out = SCRATCH / 'LO_roms'
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
