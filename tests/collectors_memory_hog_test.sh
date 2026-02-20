#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/collectors.sh"

output="$(collect_memory_hog_context "  ")"
[[ "$output" == *"Top memory hog:"* ]] || { echo "expected memory hog output" >&2; exit 1; }

echo "collectors_memory_hog_test: PASS"
