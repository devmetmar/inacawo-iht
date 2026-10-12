# day1

Templates for the **first** hindcast day (ramp tides / startup IC).

Used when running:

```bash
# Prefer: ./run_hindcast.bash --start YYYYMMDD --end YYYYMMDD --day1
python modify_dot_in.py YYYYMMDD YYYYMMDD --day1
export IHT_START_DATE=YYYYMMDD IHT_END_DATE=YYYYMMDD
bash copy_files_for_run_day1.bash
```

Sibling default templates (continuing days) live in the parent `in_templates/` directory.
