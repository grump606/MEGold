"""Run each test script in its own process; fixtures cannot leak between suites."""
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
scripts = sorted((ROOT / "tests").glob("test_*.py"))
failed = []
for script in scripts:
    print(f"\nRunning {script.name}", flush=True)
    result = subprocess.run([sys.executable, str(script)], cwd=ROOT, check=False)
    if result.returncode:
        failed.append(script.name)
if failed:
    print("\nFAILED: " + ", ".join(failed))
    raise SystemExit(1)
print(f"\nPASS: {len(scripts)} isolated test scripts")
