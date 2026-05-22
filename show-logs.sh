#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Burble Log Viewer - View all launcher logs with timestamps

set -euo pipefail

LOG_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/burble"

# Create log directory if it doesn't exist
mkdir -p "$LOG_DIR"

echo "═══════════════════════════════════════════════════════════════════════════════"
echo "  Burble Launcher Logs - $(date '+%Y-%m-%d %H:%M:%S')"
echo "  Log directory: $LOG_DIR"
echo "═══════════════════════════════════════════════════════════════════════════════"
echo ""

# Show available log files
 echo "Available log files:"
ls -la "$LOG_DIR" | grep -E '\.log$' || echo "  No log files found yet"
echo ""

# Show combined logs in chronological order
echo "═══════════════════════════════════════════════════════════════════════════════"
echo "Combined logs (most recent first):"
echo "═══════════════════════════════════════════════════════════════════════════════"

# Show all log files combined, sorted by timestamp
find "$LOG_DIR" -name "*.log" -exec echo "=== {} ===" \; -exec tail -100 {} \; | sort -r

echo ""
echo "═══════════════════════════════════════════════════════════════════════════════"
echo "Log viewing complete"
echo "To watch logs in real-time: tail -f $LOG_DIR/*.log"
echo "═══════════════════════════════════════════════════════════════════════════════"
