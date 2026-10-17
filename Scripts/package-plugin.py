#!/usr/bin/env python3
"""Create a portable ZIP32 .dip archive; the Host still validates on import."""
from pathlib import Path
import sys

# Preserve the repository CLI while the portable SDK owns the implementation.
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'SDK' / 'tools'))
from package_plugin import main, package  # noqa: E402,F401


if __name__ == '__main__':
    main()
