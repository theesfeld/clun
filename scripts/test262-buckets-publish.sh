#!/bin/sh

set -eu

if [ "$#" -ne 4 ]; then
  printf 'usage: %s GENERATED_GAPS GENERATED_REPORT CANONICAL_GAPS CANONICAL_REPORT\n' \
    "$0" >&2
  exit 2
fi

generated_gaps=$1
generated_report=$2
canonical_gaps=$3
canonical_report=$4

for path in "$generated_gaps" "$generated_report" "$canonical_gaps" "$canonical_report"; do
  [ -f "$path" ] || {
    printf 'test262-buckets-publish: missing file: %s\n' "$path" >&2
    exit 2
  }
done

gaps_backup=$canonical_gaps.publish-backup.$$
report_backup=$canonical_report.publish-backup.$$
committed=false

rollback() {
  status=$?
  trap - 0 HUP INT TERM
  if [ "$committed" != true ]; then
    if [ -f "$gaps_backup" ]; then
      mv -f "$gaps_backup" "$canonical_gaps"
    fi
    if [ -f "$report_backup" ]; then
      mv -f "$report_backup" "$canonical_report"
    fi
  fi
  rm -f "$gaps_backup" "$report_backup"
  exit "$status"
}

trap rollback 0
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

[ ! -e "$gaps_backup" ] && [ ! -e "$report_backup" ] || {
  printf '%s\n' 'test262-buckets-publish: backup path already exists' >&2
  exit 2
}

cp -p "$canonical_gaps" "$gaps_backup"
cp -p "$canonical_report" "$report_backup"
mv -f "$generated_gaps" "$canonical_gaps"
mv -f "$generated_report" "$canonical_report"
committed=true
rm -f "$gaps_backup" "$report_backup"

printf '%s\n' 'test262-buckets-publish: canonical inventory updated'
