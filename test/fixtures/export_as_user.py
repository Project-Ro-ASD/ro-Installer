#!/usr/bin/python3 -I
"""Test-only child privilege drop for root-run CI; production exporter refuses root."""
import os
from pathlib import Path
import runpy
if os.geteuid() == 0:
    os.setgroups([])
    os.setgid(65534)
    os.setuid(65534)
runpy.run_path(str(Path(__file__).resolve().parents[2]/'linux/ro-installer-export'),run_name='__main__')
