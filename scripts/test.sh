#!/bin/bash
#
# Fork addition: runs the test suite with only the Command Line Tools installed.
#
# Xcode puts the Swift Testing framework on the search path by itself; the
# Command Line Tools ship it too, but `swift test` does not look there, so the
# tests fail with "no such module 'Testing'". Pointing the compiler and linker
# at it is all that is missing. With Xcode installed this behaves like a plain
# `swift test`.
#
# Usage: scripts/test.sh [extra swift test arguments, e.g. --filter ChatGPT]

set -euo pipefail

cd "$(dirname "$0")/.."

developer="$(xcode-select -p)"
frameworks="$developer/Library/Developer/Frameworks"
libs="$developer/Library/Developer/usr/lib"

if [[ -d "$frameworks/Testing.framework" ]]; then
    exec swift test \
        -Xswiftc -F -Xswiftc "$frameworks" \
        -Xlinker -F -Xlinker "$frameworks" \
        -Xlinker -rpath -Xlinker "$frameworks" \
        -Xlinker -rpath -Xlinker "$libs" \
        "$@"
fi
exec swift test "$@"
