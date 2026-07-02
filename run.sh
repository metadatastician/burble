#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Burble Run Script — quick start wrapper

set -euo pipefail

# ============================================================================
# LOGGING SETUP
# ============================================================================
LOG_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/burble"
mkdir -p "$LOG_DIR"
RUN_LOG="$LOG_DIR/run-wrapper.log"

trace() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S.%3N')] [TRACE] [RUN-WRAPPER] $1" >> "$RUN_LOG"
}

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S.%3N')] [INFO]  [RUN-WRAPPER] $1"
  echo "[$(date '+%Y-%m-%d %H:%M:%S.%3N')] [INFO]  [RUN-WRAPPER] $1" >> "$RUN_LOG"
}

err() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S.%3N')] [ERROR] [RUN-WRAPPER] $1" >&2
  echo "[$(date '+%Y-%m-%d %H:%M:%S.%3N')] [ERROR] [RUN-WRAPPER] $1" >> "$RUN_LOG"
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

START_TIME=$(date +%s.%N)
log "Run wrapper started with args: $*"
trace "Current directory: $(pwd)"

BURBLE_DIR="$(cd "$(dirname "$0")" && pwd)"
trace "BURBLE_DIR resolved to: $BURBLE_DIR"

LAUNCHER_SCRIPT="$BURBLE_DIR/burble-launcher.sh"
trace "Calling launcher script: $LAUNCHER_SCRIPT"
trace "Arguments: $*"

# Call the main launcher script
trace "Executing launcher script"
exec "$LAUNCHER_SCRIPT" "$@"
