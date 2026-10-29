#!/usr/bin/env python3 -I
"""Where a `sample` capture's time actually went.

`sample` counts wall-clock presence, so most of any thread is parked in
`mach_msg` or a workqueue wait — huge totals that are not work. This keeps only
the samples whose innermost frame is doing something, then:

1. counts that work per thread,
2. splits the main thread into what SwiftUI and AppKit were doing,
3. ranks the binary's own functions by the work under them.

Usage: Tools/attribute.py sample.txt [binary name, default gruppen-bench]
"""
import re
import sys

PATH = sys.argv[1]
BINARY = sys.argv[2] if len(sys.argv) > 2 else "gruppen-bench"

IDLE = ("mach_msg2_trap", "__workq_kernreturn", "__psynch_cvwait", "__semwait_signal",
        "kevent", "__select", "__ulock_wait", "start_wqthread", "thread_start")
# Innermost ancestor wins, so these read from most to least specific.
MAIN_BUCKETS = [
    ("RunningAppTracker", "running-app refresh"),
    ("_XCopyAttributeValue", "accessibility queries (another app)"),
    ("TelemetryModule.accept", "applying readings"),
    ("CTLine", "text"), ("CTFont", "text"), ("StyledText", "text"), ("StringDrawing", "text"),
    ("renderDisplayList", "SwiftUI render"), ("DisplayList", "SwiftUI render"),
    ("sizeThatFits", "SwiftUI layout"), ("placeChildren", "SwiftUI layout"),
    ("explicitAlignment", "SwiftUI layout"), ("lengthThatFits", "SwiftUI layout"),
    ("body.getter", "SwiftUI view bodies"), ("flushTransactions", "SwiftUI update"),
    ("CA::Layer", "Core Animation layers"), ("CA::Transaction", "Core Animation commit"),
]


def threads(lines):
    """(thread name, [(depth, count, frame)]) for each thread in the call tree."""
    current, entries = None, []
    for line in lines:
        if line.startswith("Total number in stack"):
            break
        header = re.match(r"^    (\d+) (Thread_\S+.*)$", line)
        if header:
            if current:
                yield current, entries
            current, entries = header.group(2).strip(), []
            continue
        frame = re.match(r"^([ +!:|]*)(\d+) (.*)$", line)
        if frame and current:
            entries.append((len(frame.group(1)), int(frame.group(2)), frame.group(3)))
    if current:
        yield current, entries


def leaves(entries):
    """Each leaf's count with the path of frames above it."""
    path = []
    for index, (depth, count, frame) in enumerate(entries):
        while path and path[-1][0] >= depth:
            path.pop()
        path.append((depth, frame))
        following = entries[index + 1] if index + 1 < len(entries) else None
        if following is None or following[0] <= depth:
            yield count, [f for _, f in path]


def name(frame):
    return re.sub(r"\s+\(in .*$", "", frame).strip()


lines = open(PATH).read().split("\n")
per_thread, main, ours = {}, {}, {}
for thread, entries in threads(lines):
    label = re.sub(r"Thread_\d+:?\s*", "", thread) or thread
    for count, path in leaves(entries):
        if name(path[-1]).startswith(IDLE):
            continue
        per_thread[label] = per_thread.get(label, 0) + count
        own = [name(f) for f in path if f"(in {BINARY})" in f
               and not re.search(r"thunk|partial apply|deduplicated|\.main\(\)|^main\b", name(f))]
        if own:
            ours[own[-1]] = ours.get(own[-1], 0) + count
        if "Main Thread" in thread:
            bucket = next((b for f in reversed(path) for key, b in MAIN_BUCKETS if key in f), "other")
            main[bucket] = main.get(bucket, 0) + count

# The main thread is in every sample, so its count is the duration in ticks.
interval = re.search(r"every ([\d.]+) millisecond", lines[0])
main_ticks = next((int(m.group(1)) for line in lines
                   if (m := re.match(r"^    (\d+) Thread_\S+: Main Thread", line))), None)
seconds = main_ticks * float(interval.group(1)) / 1000 if interval and main_ticks else None
total = sum(per_thread.values())
share = f" in {seconds:.0f} s, ≈ {total * float(interval.group(1)) / 1000 / seconds * 100:.2f}% of a core" if seconds else ""
print(f"## Work: {total} samples{share}")
for label, count in sorted(per_thread.items(), key=lambda kv: -kv[1])[:8]:
    print(f"{count:6d}  {label[:80]}")
print("\n## Main thread")
for label, count in sorted(main.items(), key=lambda kv: -kv[1]):
    print(f"{count:6d}  {label}")
print(f"\n## {BINARY}'s own functions (innermost)")
for label, count in sorted(ours.items(), key=lambda kv: -kv[1])[:20]:
    print(f"{count:6d}  {label[:110]}")
