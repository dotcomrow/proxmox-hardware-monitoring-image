#!/bin/bash
set -euo pipefail

METRICS_FILE="/opt/dell-exporter/metrics.prom"
OMREPORT="/opt/dell/srvadmin/bin/omreport"

if [[ ! -x "$OMREPORT" ]]; then
  echo "omreport not found!" >&2
  exit 1
fi

# Clear previous metrics
{
  echo "# HELP dell_system_metrics Dell hardware metrics collected via omreport"
  echo "# TYPE dell_system_metrics gauge"
} > "$METRICS_FILE"

collect_and_format() {
  local section=$1
  shift
  echo "Collecting: $section $*" >&2

  if ! output="$($OMREPORT "$section" "$@" 2>/dev/null)"; then
    echo "⚠️ Failed to collect: $section $*" >&2
    return
  fi

  awk -v prefix="${section// /_}" '
    BEGIN {
      metric_name = "dell_" prefix
    }

    /^[A-Za-z]/ {
      gsub(/\r/, "")
      split($0, kv, ":")
      key = kv[1]
      value = kv[2]

      # Cleanup key and value
      gsub(/^[ \t]+|[ \t]+$/, "", key)
      gsub(/[^a-zA-Z0-9_]/, "_", key)
      gsub(/^[ \t]+|[ \t]+$/, "", value)

      if (value ~ /^-?[0-9]+(\.[0-9]+)?$/) {
        printf "%s{key=\"%s\"} %s\n", metric_name, key, value
      }
    }
  ' <<< "$output" >> "$METRICS_FILE"
}

# Main collect calls
collect_and_format chassis
collect_and_format "chassis temps"
collect_and_format "chassis fans"
collect_and_format "chassis pwrsupplies"
collect_and_format "chassis batteries"
collect_and_format "chassis processors"
collect_and_format "chassis memory"
collect_and_format "chassis nics"
collect_and_format "system summary"
collect_and_format "storage controller"
collect_and_format "storage vdisk"
collect_and_format "storage pdisk" controller=0
collect_and_format "storage battery"
