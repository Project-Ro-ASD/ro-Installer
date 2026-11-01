"""Pure JSON oracle for cross-language manual-plan tests; no device probes."""
import importlib.util
import json
from pathlib import Path
import sys

spec = importlib.util.spec_from_file_location('parity_gpt', Path(__file__).resolve().parents[2] / 'linux/ro_installer_gpt.py')
gpt = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gpt)
results = []
for value in json.loads(sys.argv[1]):
    try:
        results.append({'ok': True, 'plan': gpt.manual_plan(value['snapshot'], {role: value[role] for role in ('esp', 'root')})})
    except (ValueError, KeyError, TypeError):
        results.append({'ok': False})
print(json.dumps(results, separators=(',', ':')))
