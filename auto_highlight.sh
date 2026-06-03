#!/usr/bin/env bash
set -eu -o pipefail

# auto_highlight.sh
# Usage: ./auto_highlight.sh input.mp4 output.mp4
# Default behavior preserves debug artifacts; set KEEP_DEBUG=0 for cleanup.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
KEEP_DEBUG=0 exec "$SCRIPT_DIR/auto_highlight_core.sh" "$@"
