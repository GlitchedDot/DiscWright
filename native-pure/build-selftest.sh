#!/bin/bash
# Build the DiscWright Swift-core self-test. Run in Terminal (macOS):
#     cd <this folder>
#     ./build-selftest.sh
#     ./selftest ../reference
set -e
cd "$(dirname "$0")"

if ! xcrun --find swiftc >/dev/null 2>&1; then
  echo "The Swift compiler was not found."
  echo "Install Apple's free Command Line Tools first, in Terminal:"
  echo "    xcode-select --install"
  echo "When that finishes, run ./build-selftest.sh again."
  exit 1
fi

# swiftc allows top-level code in only one place: a file named
# main.swift. The self-test's entry point therefore lives in
# selftest.swift and is staged under that name for the compile.
BUILD_DIR=".selftest-build"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
cp selftest.swift "$BUILD_DIR/main.swift"

echo "Compiling the DiscWright Swift core + self-test..."
swiftc -O core/*.swift "$BUILD_DIR/main.swift" -o selftest
rm -rf "$BUILD_DIR"

echo ""
echo "Done: ./selftest"
echo "Check byte-parity against the reference fixture with:"
echo "    ./selftest ../reference"
