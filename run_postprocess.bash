#!/bin/bash
# Thin wrapper so ./run_postprocess.bash works from the iht repo root.
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/postprocess/run_postprocess.bash" "$@"
