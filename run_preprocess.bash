#!/bin/bash
# Thin wrapper so ./run_preprocess.bash works from the iht repo root.
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/preprocess/run_preprocess.bash" "$@"
