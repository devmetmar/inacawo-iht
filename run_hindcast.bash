#!/bin/bash
# Thin wrapper so ./run_hindcast.bash works from the iht repo root.
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/hindcast_run/run_hindcast.bash" "$@"
