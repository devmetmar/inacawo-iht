from datetime import datetime, timedelta
import os
import shutil


def modify_dot_in_roms(start_date, end_date, day1=False):
    from pathlib import Path

    cawo_run = os.environ.get("CAWO_HINDCAST_RUN")
    in_templates = os.environ.get("IN_TEMPLATES")
    roms_forcing = os.environ.get("ROMS_FORCING")
    grid_data = os.environ.get("GRID_DATA")
    cawo_output = os.environ.get("CAWO_OUTPUT")

    if cawo_run is None or in_templates is None:
        raise EnvironmentError("Required environment variables are not set.")

    directory_prefix = f"{cawo_run}/f"

    template_dir = Path(in_templates) / ("day1" if day1 else "")
    source_file = template_dir / "roms.in.template"

    current_date = start_date
    while current_date <= end_date:
        date_str = current_date.strftime("%Y%m%d")
        next_date = current_date + timedelta(days=1)
        prev_date = current_date - timedelta(days=1)

        dest_dir = Path(directory_prefix + date_str)
        dest_dir.mkdir(parents=True, exist_ok=True)

        dest_file = dest_dir / "roms.in"
        shutil.copy(source_file, dest_file)

        with open(dest_file, "r") as f:
            content = f.read()

        ref_time = datetime(1858, 11, 17)
        dstart = ((current_date + timedelta(hours=12) - ref_time).total_seconds()) / (24 * 3600)

        content = content.replace("DSTART =  dstart", f"DSTART =  {dstart}d0")
        content = content.replace("today", date_str)
        content = content.replace("tomorrow", next_date.strftime("%Y%m%d"))
        content = content.replace("yesterday", prev_date.strftime("%Y%m%d"))
        content = content.replace("ROMS_FORCING", roms_forcing or "")
        content = content.replace("STATIC_DATA", grid_data or "")
        content = content.replace("CAWO_OUTPUT", cawo_output or "")

        with open(dest_file, "w") as f:
            f.write(content)

        current_date += timedelta(days=1)
