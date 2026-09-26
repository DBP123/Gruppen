#!/bin/bash
# Compiles the whole app (minus its @main) together with Tests/ and runs the
# suite. No test framework and no Xcode project: the same swiftc invocation the
# app uses, with a different entry point, so what is exercised is the shipping
# code rather than a copy of it.
#
#   ./Tests/run.sh            run as this Mac's architecture
#   ./Tests/run.sh x86_64     run as Intel, under Rosetta on Apple silicon
#
# Run this in a normal shell. Inside a sandbox that denies writes to
# /var/folders/…/T — which is what `NSTemporaryDirectory()` returns regardless of
# $TMPDIR — around forty checks fail on fixture directories that could not be
# created, and the SMC declines to open, so the power basis falls back from the
# live rail to the battery meter. Those failures are the sandbox, not the code.
set -euo pipefail
cd "$(dirname "$0")/.."

ARCH="${1:-$(uname -m)}"
OUT="build/suite-$ARCH"

SDK_ROOT="$(dirname "$(xcrun --show-sdk-path)")"
if [ -d "${SDK_ROOT}/MacOSX26.sdk" ]; then
    SDK="${SDK_ROOT}/MacOSX26.sdk"
else
    SDK="$(xcrun --show-sdk-path)"
fi

mkdir -p build
echo "Building the suite for ${ARCH}..."
xcrun swiftc \
    -parse-as-library \
    -sdk "$SDK" \
    -target "${ARCH}-apple-macos13.0" \
    -o "$OUT" \
    $(find Sources -name '*.swift' ! -name 'GruppenApp.swift' | sort) \
    $(find Tests -name '*.swift' | sort)

if [ "$ARCH" = "$(uname -m)" ]; then
    "$OUT"
else
    arch -"$ARCH" "$OUT"
fi
