from datetime import timedelta
import os
import shutil
from pathlib import Path


def modify_dot_in_wrf(start_date, end_date, day1=False):
    cawo_run = os.environ.get("CAWO_HINDCAST_RUN")
    cawo_output = os.environ.get("CAWO_OUTPUT")
    in_templates = os.environ.get("IN_TEMPLATES")

    if cawo_run is None or cawo_output is None or in_templates is None:
        raise EnvironmentError("Required environment variables are not set.")

    directory_prefix = f"{cawo_run}/f"

    template_dir = Path(in_templates) / ("day1" if day1 else "")
    source_file = template_dir / "namelist.input.template"

    current_date = start_date
    while current_date <= end_date:
        date_str = current_date.strftime("%Y%m%d")

        next_date = current_date + timedelta(days=1)
        prev_date = current_date - timedelta(days=1)

        yyyy, mm, dd = current_date.strftime("%Y"), current_date.strftime("%m"), current_date.strftime("%d")
        yyyy2, mm2, dd2 = next_date.strftime("%Y"), next_date.strftime("%m"), next_date.strftime("%d")

        dest_dir = Path(directory_prefix + date_str)
        dest_dir.mkdir(parents=True, exist_ok=True)

        dest_file = dest_dir / "namelist.input"
        shutil.copy(source_file, dest_file)

        with open(dest_file, "r") as f:
            content = f.read()

        content = content.replace("today", date_str)
        content = content.replace("tomorrow", next_date.strftime("%Y%m%d"))
        content = content.replace("yesterday", prev_date.strftime("%Y%m%d"))

        content = content.replace("YYYY1", yyyy)
        content = content.replace("MM1", mm)
        content = content.replace("DD1", dd)

        content = content.replace("YYYY2", yyyy2)
        content = content.replace("MM2", mm2)
        content = content.replace("DD2", dd2)

        content = content.replace("CAWO_OUTPUT", cawo_output)

        with open(dest_file, "w") as f:
            f.write(content)

        current_date += timedelta(days=1)
