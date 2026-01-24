#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import argparse
from datetime import datetime
from utils import (
    modify_dot_in_roms,
    modify_dot_in_swan,
    modify_dot_in_wrf,
)


def main():
    parser = argparse.ArgumentParser(
        description="Modify ROMS, SWAN, and WRF input templates for a given date range."
    )

    parser.add_argument("start_date", type=str, help="Start date in YYYYMMDD format")
    parser.add_argument("end_date", type=str, help="End date in YYYYMMDD format")
    parser.add_argument("--day1", action="store_true", help="Use day1 templates (if available).",)
    parser.add_argument("--models", nargs="+", default=["roms", "swan", "wrf"], choices=["roms", "swan", "wrf", "all"],
        help="Models to process: roms, swan, wrf, or all (default: all).",
    )

    args = parser.parse_args()

    start_date = datetime.strptime(args.start_date, "%Y%m%d")
    end_date = datetime.strptime(args.end_date, "%Y%m%d")

    # Normalize models argument
    if "all" in args.models:
        models = ["roms", "swan", "wrf"]
    else:
        models = args.models

    print(f"Start date: {args.start_date}")
    print(f"End date  : {args.end_date}")
    print(f"Day1 mode : {args.day1}")
    print(f"Models   : {', '.join(models)}")
    print("-" * 50)

    if "roms" in models:
        print("=== Modifying ROMS input files ===")
        modify_dot_in_roms(start_date, end_date, day1=args.day1)

    if "swan" in models:
        print("=== Modifying SWAN input files ===")
        modify_dot_in_swan(start_date, end_date, day1=args.day1)

    if "wrf" in models:
        print("=== Modifying WRF input files ===")
        modify_dot_in_wrf(start_date, end_date, day1=args.day1)

    print("\nAll .in files updated successfully.")


if __name__ == "__main__":
    main()
