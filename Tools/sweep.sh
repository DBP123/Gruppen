#!/bin/bash
# A sweep for dead, weak and inefficient code. Writes its findings to
# build/sweep/ — read them, don't act on them blindly: every line is a
# candidate with evidence, not a verdict.
#
#   Tools/sweep.sh            compiler, references, patterns, coverage
#   Tools/sweep.sh --quick    without coverage (no test run)
#
# Run in a normal shell: coverage runs the test suite, which needs the window
# server and a writable temporary folder.
set -uo pipefail
cd "$(dirname "$0")/.."
source sdk.sh

OUT="build/sweep"
mkdir -p "$OUT"
SOURCES=$(find Sources -name '*.swift' | sort)
APP_SOURCES=$(find Sources -name '*.swift' ! -name 'GruppenApp.swift' | sort)
TESTS=$(find Tests -name '*.swift' | sort)

echo "1/4 Compiler — every warning, strict concurrency"
xcrun swiftc -typecheck -parse-as-library -sdk "$SDK" -target "$(uname -m)-apple-macos13.0" \
    -strict-concurrency=complete $SOURCES 2>&1 \
    | grep -E "warning:|error:" | sed -E 's/^.*Sources\//Sources\//' | sort -u > "$OUT/compiler.txt"
echo "    $(wc -l < "$OUT/compiler.txt" | tr -d ' ') diagnostics → $OUT/compiler.txt"

echo "2/4 References — declarations nothing uses"
python3 -I Tools/refscan.py . > "$OUT/references.txt"
echo "    $(grep -cE '^Sources/' "$OUT/references.txt") candidates → $OUT/references.txt"

echo "3/4 Patterns — weak and repeated-work code"
{
    section() { echo; echo "## $1"; echo; }
    section "try? (a failure that may deserve a log line or the user)"
    grep -rnE 'try\?' Sources | grep -vE '//.*try\?'
    section "Force unwraps, force casts, fatalError"
    grep -rnE '[A-Za-z0-9_)\]]!(\.|\)| |$)|as! |fatalError\(' Sources | grep -vE '!=|//'
    section "One-shot delays used as timers"
    grep -rnE 'asyncAfter|Task\.sleep' Sources
    section "Formatters, regexes and detectors built per call"
    grep -rnE '= (ISO8601)?DateFormatter\(\)|NSRegularExpression\(|NSDataDetector\(|try Regex' Sources
    section "File system work in views (runs on every render)"
    grep -lE ': View \{' $SOURCES | xargs grep -nE 'FileManager\.default|contentsOfDirectory|fileExists'
    section "@unchecked Sendable and nonisolated(unsafe) — each needs a reason"
    grep -rnE '@unchecked Sendable|nonisolated\(unsafe\)' Sources
    section "Notes left in code"
    grep -rnE 'TODO|FIXME|HACK|XXX' Sources
} > "$OUT/patterns.txt" 2>/dev/null
echo "    → $OUT/patterns.txt"

if [ "${1:-}" = "--quick" ]; then exit 0; fi

echo "4/4 Coverage — what the suite never runs"
BIN="$OUT/suite-coverage"
xcrun swiftc -parse-as-library -sdk "$SDK" -target "$(uname -m)-apple-macos13.0" \
    -profile-generate -profile-coverage-mapping -o "$BIN" $APP_SOURCES $TESTS 2>/dev/null
LLVM_PROFILE_FILE="$OUT/suite.profraw" "$BIN" > "$OUT/suite-run.txt" 2>&1
xcrun llvm-profdata merge -sparse "$OUT/suite.profraw" -o "$OUT/suite.profdata"
xcrun llvm-cov report "$BIN" -instr-profile "$OUT/suite.profdata" $APP_SOURCES > "$OUT/coverage-files.txt"
xcrun llvm-cov export "$BIN" -instr-profile "$OUT/suite.profdata" -format=text $APP_SOURCES \
    | python3 -I Tools/coverage.py > "$OUT/coverage-never-run.txt"
echo "    $(wc -l < "$OUT/coverage-never-run.txt" | tr -d ' ') functions never run → $OUT/coverage-never-run.txt"
tail -1 "$OUT/coverage-files.txt"
