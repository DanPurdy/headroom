#!/bin/bash
# Runs the test suite. With only the Command Line Tools selected (no Xcode), swift-testing
# ships but isn't on the default search paths, so point the compiler and linker at it.
set -euo pipefail
cd "$(dirname "$0")/.."

developer_dir=$(xcode-select -p)
if [[ "$developer_dir" == *CommandLineTools* ]]; then
  frameworks="$developer_dir/Library/Developer/Frameworks"
  libs="$developer_dir/Library/Developer/usr/lib"
  exec swift test -Xswiftc -F"$frameworks" -Xlinker -F"$frameworks" \
    -Xlinker -rpath -Xlinker "$frameworks" -Xlinker -rpath -Xlinker "$libs" "$@"
fi
exec swift test "$@"
