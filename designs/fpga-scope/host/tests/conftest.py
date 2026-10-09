import sys
from pathlib import Path

# make the package and the SV golden model importable
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "host"))
sys.path.insert(0, str(ROOT / "sim" / "model"))
