#!/bin/sh
set -euo pipefail

CRON_SCHEDULE=${BACKUP_SCHEDULE_CRON:-"0 2 * * *"}
RUN_ON_START=${RUN_BACKUP_ON_START:-true}
LOG_FILE=/var/log/restic-backup.log
SOURCES_FILE=${BACKUP_SOURCES_FILE:-/config/restic-sources.txt}
CONFIG_READY=true
MISSING_ITEMS=""

append_missing() {
  if [ -z "$MISSING_ITEMS" ]; then
    MISSING_ITEMS="$1"
  else
    MISSING_ITEMS="$MISSING_ITEMS, $1"
  fi
}

[ -z "${RESTIC_REPOSITORY:-}" ] && { append_missing "RESTIC_REPOSITORY"; CONFIG_READY=false; }
[ -z "${RESTIC_PASSWORD:-}" ] && { append_missing "RESTIC_PASSWORD"; CONFIG_READY=false; }
[ ! -f "$SOURCES_FILE" ] && { append_missing "$SOURCES_FILE"; CONFIG_READY=false; }

if [ "$CONFIG_READY" = false ]; then
  touch "$LOG_FILE"
  echo "[restic-backup] configuration incomplete (missing: $MISSING_ITEMS); container idling until variables/files are provided" | tee -a "$LOG_FILE"
  tail -f /dev/null
fi

echo "$CRON_SCHEDULE /app/run-backup.sh >> $LOG_FILE 2>&1" > /etc/crontabs/root

if [ "$RUN_ON_START" = "true" ]; then
  if ! /app/run-backup.sh >> "$LOG_FILE" 2>&1; then
    echo "[restic-backup] initial RUN_ON_START execution failed; cron will retry" | tee -a "$LOG_FILE"
  fi
fi

exec crond -f -l 8
