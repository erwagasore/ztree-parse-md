#!/usr/bin/env bash
# Check if bun-md uses any bun.* APIs the shim doesn't cover.
#
# Usage: ./scripts/check-shim.sh [path-to-bun-md]
#
# Compares bun.* references in bun-md source against a known list.
# Prints new APIs that need adding to src/shim/bun.zig.

set -euo pipefail

BUN_MD="${1:-../bun-md}"

KNOWN="bun.JSError
bun.StackCheck
bun.StackCheck.init
bun.StackOverflow
bun.StringHashMapUnmanaged
bun.bit_set.StaticBitSet
bun.strings.codepointSize
bun.strings.decodeWTF
bun.strings.encodeWTF
bun.strings.eqlCaseInsensitiveASCIIICheckLength
bun.strings.eqlCaseInsensitiveASCIIIgnoreLength
bun.strings.indexOfAny
bun.strings.indexOfCharPos
bun.throwStackOverflow"

USED=$(grep -roh 'bun\.[a-zA-Z_.]*' "$BUN_MD/src/" | sort -u)
NEW=$(comm -23 <(echo "$USED") <(echo "$KNOWN" | sort))

if [ -z "$NEW" ]; then
    echo "✓ All bun.* APIs covered by shim"
else
    echo "New bun.* APIs — add to src/shim/bun.zig:"
    echo "$NEW" | sed 's/^/  /'
    exit 1
fi
