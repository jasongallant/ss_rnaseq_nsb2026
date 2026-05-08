"""Convert EOD .mat files to JSON. Run from any directory — processes all .mat files
under subdirectories relative to this script's location."""

import glob
import json
import math
import os
import warnings

import numpy as np
import scipy.io
from scipy.io.matlab import MatlabOpaque


def to_python(obj):
    """Recursively convert numpy/mat_struct types to plain Python for JSON serialization."""
    if isinstance(obj, MatlabOpaque):  # MATLAB class object scipy can't fully deserialize
        return "<MatlabOpaque>"
    if hasattr(obj, "_fieldnames"):  # mat_struct
        return {f: to_python(getattr(obj, f)) for f in obj._fieldnames}
    if isinstance(obj, np.void):  # structured array element (e.g. from MatlabOpaque rows)
        return "<MatlabOpaque>"
    if isinstance(obj, np.ndarray):
        return [to_python(x) for x in obj.flat]
    if isinstance(obj, list):
        return [to_python(x) for x in obj]
    if isinstance(obj, np.integer):
        return int(obj)
    if isinstance(obj, np.floating):
        v = float(obj)
        return None if (math.isnan(v) or math.isinf(v)) else v
    if isinstance(obj, np.bool_):
        return bool(obj)
    if isinstance(obj, bytes):
        return obj.decode("utf-8", errors="replace")
    return obj


def convert_mat(mat_path):
    data = scipy.io.loadmat(mat_path, squeeze_me=True, struct_as_record=False)
    eod = data["eod"]

    if eod.ndim == 0:
        eod = eod.reshape(1)

    entries = []
    for i, rec in enumerate(eod):
        wave = rec.wave

        # Skip entries where wave is not an array (scalar) or is too long
        if not isinstance(wave, np.ndarray):
            continue
        if wave.size > 10000:
            continue

        entry = {
            "DeviceInfo": to_python(rec.DeviceInfo) if hasattr(rec, "DeviceInfo") else {},
            "time": to_python(rec.time),
            "date": to_python(rec.date),
            "Rate": to_python(rec.Rate),
            "wave": to_python(wave),
            "comments": to_python(rec.comments),
            "species": to_python(rec.species),
            "location": to_python(rec.location),
            "specimenno": str(to_python(rec.specimenno)),
            "gain": to_python(rec.gain),
            "amplifiercoupling": to_python(rec.amplifiercoupling),
            "temp": to_python(rec.temp),
        }
        entries.append(entry)

    return entries


def main():
    script_dir = os.path.dirname(os.path.abspath(__file__))
    mat_files = sorted(glob.glob(os.path.join(script_dir, "**", "*.mat"), recursive=True))

    if not mat_files:
        print("No .mat files found.")
        return

    for mat_path in mat_files:
        base = os.path.splitext(mat_path)[0]
        json_path = base + ".json"
        print(f"Converting {os.path.relpath(mat_path, script_dir)} ...", end=" ")
        try:
            entries = convert_mat(mat_path)
            with open(json_path, "w") as f:
                json.dump(entries, f, indent=2)
            print(f"wrote {len(entries)} entries -> {os.path.basename(json_path)}")
        except Exception as e:
            print(f"ERROR: {e}")


if __name__ == "__main__":
    main()
