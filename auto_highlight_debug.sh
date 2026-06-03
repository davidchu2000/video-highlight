#!/usr/bin/env bash
set -eu -o pipefail

# auto_highlight_debug.sh
# Usage: ./auto_highlight_debug.sh input.mp4 output.mp4
# Always preserves debug artifacts.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
KEEP_DEBUG=1 exec "$SCRIPT_DIR/auto_highlight_core.sh" "$@"
