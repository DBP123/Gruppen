#!/usr/bin/env python3 -I
"""Functions the test suite never runs, from `llvm-cov export` JSON on stdin.

Each one is either dead or untested — the reference scan says which.
"""
import json
import subprocess
import sys

data = json.load(sys.stdin)
never = [function for function in data["data"][0]["functions"] if function["count"] == 0]
demangled = subprocess.run(["xcrun", "swift-demangle", "--simplified", "--compact"],
                           input="\n".join(function["name"] for function in never),
                           capture_output=True, text=True).stdout.splitlines()

rows = []
for function, name in zip(never, demangled):
    path = function["filenames"][0].split("Sources/")[-1]
    line = function["regions"][0][0] if function["regions"] else 0
    rows.append(f"{path}:{line}  {name}")
print("\n".join(sorted(rows)))
