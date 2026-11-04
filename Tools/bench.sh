#!/bin/bash
# CPU of two builds of Gruppen on one surface, measured the only way that has
# proved trustworthy: alternated runs, compared by median.
#
#   Tools/bench.sh <surface> <a> <b> [rounds]
#
#   surface   panel | popover | dashboard | pinned | occluded | idle   (see Tools/bench/Harness.swift)
#   a, b      a git ref (HEAD, HEAD~1, a tag), "work" for the working tree, or
#             a directory holding a Sources/ tree — a patched copy, for an
#             experiment that should not touch the real one; the same build
#             twice measures the noise band
#   rounds    a/b pairs, default 3
#
#   KIND=network    which module's popover
#   PINNED=power    which modules a pinned or occluded run keeps in the menu bar
#   RUN=45          seconds measured per run, after a 6 s settle
#   SAMPLE=1        also `sample` each side's first run, and summarise it with
#                   Tools/attribute.py
#
# Run in a normal shell: it needs the window server, `top` and `sample`.
# How a run is scored: the mean of its seconds with the highest tenth dropped.
# Not the median — 1 Hz work lands in alternate one-second windows of `top`, so
# half the seconds read 0 and a median says nothing happened. Not the plain
# mean either — `top` shows 5–8% seconds that `sample` does not back up, and
# trimming the top tenth removes them. Runs are then compared by median,
# because the same build scores 0.7% one minute and 1.9% the next.
set -euo pipefail
cd "$(dirname "$0")/.."
source sdk.sh

SURFACE=${1:?surface}; A=${2:?build a}; B=${3:?build b}; ROUNDS=${4:-3}
RUN=${RUN:-45}
OUT=build/bench
mkdir -p "$OUT"

# One binary per build, always named gruppen-bench, so both sides read the same
# defaults domain and start from the same preferences.
build() {
    local ref=$1 name dir
    name=$(echo "$ref" | tr '/~^.' '____')
    dir="$OUT/$name"
    rm -rf "$dir" && mkdir -p "$dir/src"
    # Each build with the harness of its own time: the harness names the
    # app's types, and those change between versions.
    local harness=Tools/bench/Harness.swift
    if [ "$ref" = work ]; then cp -R Sources "$dir/src/"
    elif [ -d "$ref/Sources" ]; then cp -R "$ref/Sources" "$dir/src/"
    else
        git archive "$ref" Sources | tar -x -C "$dir/src"
        if git cat-file -e "$ref:Tools/bench/Harness.swift" 2>/dev/null; then
            git show "$ref:Tools/bench/Harness.swift" > "$dir/Harness.swift"
            harness="$dir/Harness.swift"
        fi
    fi
    xcrun swiftc -parse-as-library -O -whole-module-optimization -sdk "$SDK" \
        -target "$(uname -m)-apple-macos13.0" -o "$dir/gruppen-bench" \
        $(find "$dir/src/Sources" -name '*.swift' ! -name GruppenApp.swift) "$harness" \
        2>&1 | grep -E "error" >&2 && exit 1
    echo "$dir/gruppen-bench"
}

# One run: per-second CPU into a file.
measure() {
    local binary=$1 file=$2 profile=${3:-} pid
    SURFACE="$SURFACE" "$binary" > /dev/null 2>&1 & pid=$!
    sleep 6
    [ -n "$profile" ] && sample "$pid" 20 -file "$profile" > /dev/null 2>&1 &
    top -l $((RUN + 1)) -s 1 -pid "$pid" -stats pid,cpu | awk -v pid="$pid" '$1==pid {print $2}' | tail -"$RUN" > "$file"
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null || true
}

echo "building ${A} and ${B}…"
BIN_A=$(build "$A")
BIN_B=$([ "$B" = "$A" ] && echo "$BIN_A" || build "$B")

for round in $(seq 1 "$ROUNDS"); do
    for side in a b; do
        binary=$([ $side = a ] && echo "$BIN_A" || echo "$BIN_B")
        profile=""
        [ -n "${SAMPLE:-}" ] && [ "$round" = 1 ] && profile="$OUT/sample-$SURFACE-$side.txt"
        measure "$binary" "$OUT/run-$side-$round.txt" "$profile"
        printf "  round %d %s  %s%%\n" "$round" "$side" "$(python3 -I -c '
import sys; v = sorted(float(x) for x in open(sys.argv[1]).read().split())
v = v[:max(1, len(v) - len(v) // 10)]; print(f"{sum(v) / len(v):.2f}")' "$OUT/run-$side-$round.txt")"
    done
done

python3 -I - "$OUT" "$ROUNDS" "$SURFACE" "$A" "$B" <<'EOF'
import statistics, sys
out, rounds, surface, a, b = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4], sys.argv[5]
def score(path):
    values = sorted(float(x) for x in open(path).read().split())
    kept = values[:max(1, len(values) - len(values) // 10)]
    return sum(kept) / len(kept)
def runs(side):
    return [score(f"{out}/run-{side}-{r}.txt") for r in range(1, rounds + 1)]
ra, rb = runs("a"), runs("b")
ma, mb = statistics.median(ra), statistics.median(rb)
overlap = max(min(ra), min(rb)) <= min(max(ra), max(rb))
change = (mb - ma) / ma * 100 if ma else 0
print(f"\n{surface}: {a} {ma:.2f}% (runs {min(ra):.2f}–{max(ra):.2f})  →  {b} {mb:.2f}% (runs {min(rb):.2f}–{max(rb):.2f})")
print("within noise" if overlap else f"{change:+.0f}%  {'better' if mb < ma else 'WORSE'}")
EOF

if [ -n "${SAMPLE:-}" ]; then
    for side in a b; do
        [ "$side" = b ] && [ "$B" = "$A" ] && break
        echo; echo "── where $([ $side = a ] && echo "$A" || echo "$B")'s time went ($SURFACE)"
        python3 -I Tools/attribute.py "$OUT/sample-$SURFACE-$side.txt"
    done
fi
