from datetime import timedelta
import os
import shutil
from pathlib import Path


def modify_dot_in_swan(start_date, end_date, day1=False):
    cawo_run = os.environ.get("CAWO_HINDCAST_RUN")
    cawo_input = os.environ.get("CAWO_INPUT")
    in_templates = os.environ.get("IN_TEMPLATES")

    if cawo_run is None or cawo_input is None or in_templates is None:
        raise EnvironmentError("Required environment variables are not set.")

    directory_prefix = f"{cawo_run}/f"

    template_dir = Path(in_templates) / ("day1" if day1 else "")
    source_file = template_dir / "swan.in.template"

    current_date = start_date
    while current_date <= end_date:
        date_str = current_date.strftime("%Y%m%d")
        next_date = current_date + timedelta(days=1)
        prev_date = current_date - timedelta(days=1)

        dest_dir = Path(directory_prefix + date_str)
        dest_dir.mkdir(parents=True, exist_ok=True)

        dest_file = dest_dir / "swan.in"
        shutil.copy(source_file, dest_file)

        with open(dest_file, "r") as f:
            content = f.read()

        content = content.replace("today", date_str)
        content = content.replace("tomorrow", next_date.strftime("%Y%m%d"))
        content = content.replace("yesterday", prev_date.strftime("%Y%m%d"))
        content = content.replace("CAWO_INPUT", cawo_input)

        with open(dest_file, "w") as f:
            f.write(content)

        current_date += timedelta(days=1)
