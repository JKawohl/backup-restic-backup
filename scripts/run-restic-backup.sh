#!/bin/sh
set -euo pipefail

SOURCES_FILE=${BACKUP_SOURCES_FILE:-/config/restic-sources.txt}
RETENTION_DAYS=${BACKUP_RETENTION_DAYS:-28}
RESTIC_TAG=${RESTIC_BACKUP_TAG:-daily}
METRICS_FILE=${RESTIC_METRICS_FILE:-/var/metrics/restic.prom}
LAST_SUCCESS_FILE=${RESTIC_LAST_SUCCESS_FILE:-/var/metrics/last-success.ts}

if [ -z "${RESTIC_REPOSITORY:-}" ]; then
  echo "RESTIC_REPOSITORY is not set" >&2
  exit 1
fi
if [ -z "${RESTIC_PASSWORD:-}" ]; then
  echo "RESTIC_PASSWORD is not set" >&2
  exit 1
fi

if [ ! -f "$SOURCES_FILE" ]; then
  echo "Sources file $SOURCES_FILE not found" >&2
  exit 1
fi

mkdir -p "$(dirname "$METRICS_FILE")" "$(dirname "$LAST_SUCCESS_FILE")"

write_metrics() {
  local status="$1" end_ts="$2" duration="$3"
  local success_flag=0
  local last_success=0

  if [ "$status" = "success" ]; then
    success_flag=1
    printf "%s" "$end_ts" > "$LAST_SUCCESS_FILE"
    last_success=$end_ts
  elif [ -f "$LAST_SUCCESS_FILE" ]; then
    last_success=$(cat "$LAST_SUCCESS_FILE" 2>/dev/null || echo 0)
  fi

  cat <<EOF > "$METRICS_FILE"
restic_backup_last_run_timestamp $end_ts
restic_backup_last_success_timestamp $last_success
restic_backup_duration_seconds $duration
restic_backup_success $success_flag
EOF
}

fail_and_exit() {
  local message="$1"
  echo "[restic-backup] ERROR: $message" >&2
  local now_ts
  now_ts=$(date +%s)
  write_metrics failure "$now_ts" 0
  exit 1
}

# Build argument list safely
set --
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    ''|'#'*)
      continue
      ;;
  esac
  if [ ! -e "$line" ]; then
    echo "[restic-backup] WARNING: $line does not exist, skipping" >&2
    continue
  fi
  set -- "$@" "$line"
done <"$SOURCES_FILE"

if [ "$#" -eq 0 ]; then
  echo "No valid sources to back up" >&2
  exit 1
fi

export RESTIC_PASSWORD RESTIC_REPOSITORY

tmp_err=$(mktemp)
cleanup_tmp() {
  rm -f "$tmp_err"
}
trap cleanup_tmp EXIT

restic unlock >/dev/null 2>&1 || true

if ! restic snapshots >/dev/null 2>"$tmp_err"; then
  snapshots_err=$(cat "$tmp_err")
  if printf '%s' "$snapshots_err" | grep -qi "Is there a repository"; then
    echo "[restic-backup] Repository not initialized, running restic init"
    if ! restic init >/dev/null 2>"$tmp_err"; then
      init_err=$(cat "$tmp_err")
      if printf '%s' "$init_err" | grep -qi "config file already exists"; then
        echo "[restic-backup] Repository already exists, continuing"
      else
        fail_and_exit "restic init failed: $init_err"
      fi
    fi
  else
    fail_and_exit "restic snapshots failed: $snapshots_err"
  fi
fi

echo "[restic-backup] Starting backup for $*"
start_ts=$(date +%s)
if ! restic backup --tag "$RESTIC_TAG" "$@"; then
  fail_and_exit "restic backup failed"
fi

echo "[restic-backup] Applying retention policy (keep daily $RETENTION_DAYS days)"
if ! restic forget --keep-daily "$RETENTION_DAYS" --prune; then
  fail_and_exit "restic forget/prune failed"
fi

end_ts=$(date +%s)
duration=$((end_ts - start_ts))
write_metrics success "$end_ts" "$duration"
echo "[restic-backup] Backup run completed successfully in ${duration}s"
