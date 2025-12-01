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
  # Accept the full omreport command as arguments (e.g. chassis temps)
  local args=("$@")
  local label="${args[*]}"
  echo "Collecting: $label" >&2

  local err_file out_file
  err_file="$(mktemp /tmp/omsa_collect.err.XXXXXX)"
  out_file="$(mktemp /tmp/omsa_collect.out.XXXXXX)"

  set +e
  "$OMREPORT" "${args[@]}" >"$out_file" 2>"$err_file"
  local status=$?
  set -e

  if [[ $status -ne 0 ]]; then
    echo "⚠️ Failed to collect: $label (exit $status)" >&2
    if [[ -s "$out_file" || -s "$err_file" ]]; then
      echo "---- omreport stdout/stderr ----" >&2
      tail -n 40 "$out_file" >&2 || true
      tail -n 40 "$err_file" >&2 || true
      echo "--------------------------------" >&2
    fi
    rm -f "$err_file" "$out_file"
    return
  fi

  local before after produced
  before=$(wc -l <"$METRICS_FILE" || echo 0)

  awk -v prefix="${label// /_}" '
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
  ' <"$out_file" >> "$METRICS_FILE"

  after=$(wc -l <"$METRICS_FILE" || echo 0)
  produced=$((after - before))
  echo "Collected ${produced} metrics lines from: $label" >&2

  rm -f "$err_file" "$out_file"
}

# Main collect calls
collect_and_format chassis
collect_and_format chassis temps
collect_and_format chassis fans
collect_and_format chassis pwrsupplies
collect_and_format chassis batteries
collect_and_format chassis processors
collect_and_format chassis memory
collect_and_format chassis nics
collect_and_format system summary
collect_and_format storage controller
collect_and_format storage vdisk
collect_and_format storage pdisk controller=0
collect_and_format storage battery
