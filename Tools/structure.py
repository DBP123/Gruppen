#!/usr/bin/env python3 -I
"""Shape of the code: what has grown too big, what is written twice, and what
allocates on every tick. Candidates to read, not verdicts.

Usage: Tools/structure.py <repo root>
"""
import os
import re
import sys

ROOT = sys.argv[1] if len(sys.argv) > 1 else "."
LONG_FUNCTION = 60
LARGE_TYPE = 400
WINDOW = 6          # identical non-trivial lines in a row that count as a copy


def sources():
    for root, _, files in os.walk(os.path.join(ROOT, "Sources")):
        for name in sorted(files):
            if name.endswith(".swift"):
                path = os.path.join(root, name)
                yield os.path.relpath(path, ROOT), open(path, encoding="utf-8").read()


def without_comments(text):
    """Comments blanked, line breaks kept."""
    text = re.sub(r"/\*.*?\*/", lambda m: "\n" * m.group().count("\n"), text, flags=re.S)
    return "\n".join(re.sub(r"(?<!:)//.*$", "", line) for line in text.split("\n"))


def code_only(text):
    """Comments and string contents blanked, line breaks kept, so braces count
    and line numbers survive."""
    text = re.sub(r"/\*.*?\*/", lambda m: "\n" * m.group().count("\n"), text, flags=re.S)
    text = re.sub(r'"""(.*?)"""', lambda m: '""' + "\n" * m.group(1).count("\n"), text, flags=re.S)
    text = re.sub(r'"(?:\\.|[^"\\\n])*"', '""', text)
    return "\n".join(re.sub(r"//.*$", "", line) for line in text.split("\n"))


def spans(code, pattern):
    """(name, first line, line count) for each declaration matching `pattern`,
    measured from its line to its closing brace."""
    lines = code.split("\n")
    for number, line in enumerate(lines):
        match = re.search(pattern, line)
        if not match:
            continue
        depth, opened = 0, False
        for end in range(number, len(lines)):
            depth += lines[end].count("{") - lines[end].count("}")
            opened = opened or "{" in lines[end]
            if opened and depth <= 0:
                yield next(g for g in match.groups() if g), number + 1, end - number + 1
                break


files = list(sources())
codes = {path: code_only(text) for path, text in files}

print(f"## Functions over {LONG_FUNCTION} lines\n")
long_functions = [(lines, path, start, name)
                  for path, code in codes.items()
                  for name, start, lines in spans(code, r"\bfunc\s+(?P<name>\w+)")
                  if lines > LONG_FUNCTION]
for lines, path, start, name in sorted(long_functions, reverse=True):
    print(f"{path}:{start}  {name}  {lines} lines")

print(f"\n## Types over {LARGE_TYPE} lines\n")
large = [(lines, path, start, name)
         for path, code in codes.items()
         for name, start, lines in spans(code, r"^(?:\s{0,4})(?:@\w+\s+)*(?:(?:private|fileprivate|final|public)\s+)*"
                                                r"(?:struct|class|enum|actor)\s+(?P<name>\w+)")
         if lines > LARGE_TYPE]
for lines, path, start, name in sorted(large, reverse=True):
    print(f"{path}:{start}  {name}  {lines} lines")

print(f"\n## Repeated blocks ({WINDOW}+ identical lines in more than one place)\n")
# Strings kept: blanked, every `case .x: return "…"` table would look like a copy
# of every other one. Runs that are nothing but cases are tables, not copies.
seen = {}
for path, text in files:
    meaningful = [(number + 1, re.sub(r"\s+", " ", line).strip())
                  for number, line in enumerate(without_comments(text).split("\n"))]
    meaningful = [(n, line) for n, line in meaningful
                  if len(line) > 12 and not re.match(r"(case |default:|switch )", line)]
    for index in range(len(meaningful) - WINDOW + 1):
        block = tuple(line for _, line in meaningful[index:index + WINDOW])
        seen.setdefault(block, []).append((path, meaningful[index][0]))
reported = []
for block, places in seen.items():
    distinct = sorted(set(places))
    if len(distinct) < 2:
        continue
    # A long copy is many overlapping windows; report its first only. A window
    # continues an earlier report when one of its places sits just past one
    # of that report's places, in the same file.
    if any(any(path == p and 0 < line - l <= WINDOW for path, line in distinct for p, l in earlier)
           for earlier in reported):
        reported.append(distinct)
        continue
    reported.append(distinct)
    print("  " + "  ≈  ".join(f"{path}:{line}" for path, line in distinct) + f"   «{block[0][:60]}»")

print("\n## Allocation inside per-tick code (telemetry samplers and views)\n")
for path, code in codes.items():
    if "Telemetry" not in path:
        continue
    lines_of = code.split("\n")
    for match_name, start, lines in spans(code, r"\bfunc\s+(sample)\s*\(|\b(body)\s*:\s*some View"):
        chunk = "\n".join(lines_of[start - 1:start - 1 + lines])
        hits = len(re.findall(r"\.(?:map|filter|sorted|compactMap|flatMap|reduce)\s*[({]|String\(format:", chunk))
        if hits >= 4:
            print(f"{path}:{start}  {match_name}  {hits} map/filter/sort/format")
