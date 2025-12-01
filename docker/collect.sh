#!/bin/bash
set -euo pipefail

METRICS_FILE="/opt/dell-exporter/metrics.prom"
OMREPORT="/opt/dell/srvadmin/bin/omreport"
TMP_METRICS="$(mktemp /opt/dell-exporter/metrics.prom.tmp.XXXXXX)"
trap 'rm -f "$TMP_METRICS"' EXIT
SMARTCTL_BIN="${SMARTCTL_BIN:-/usr/sbin/smartctl}"
SMART_BASE_DEVICE="${SMART_BASE_DEVICE:-/dev/sda}"
SMART_MAX_DRIVES="${SMART_MAX_DRIVES:-32}"
SMART_ENABLE="${SMART_ENABLE:-true}"
SMART_CONTROLLER_ID="${SMART_CONTROLLER_ID:-0}"

if [[ ! -x "$OMREPORT" ]]; then
  echo "omreport not found!" >&2
  exit 1
fi

# Start fresh metrics into a temp file (atomic move at the end avoids partial reads)
{
  echo "# HELP dell_system_metrics Dell hardware metrics collected via omreport"
  echo "# TYPE dell_system_metrics gauge"
} > "$TMP_METRICS"

sanitize_label() {
  local val="$1"
  # Replace unsafe chars with underscore
  val="${val//[^A-Za-z0-9_]/_}"
  val="${val##_}"; val="${val%%_}"
  echo "$val"
}

collect_and_format() {
  # Accept the full omreport command as arguments (e.g. chassis temps)
  local args=("$@")
  local label="${args[*]}"
  local prefix="${label// /_}"
  prefix="${prefix//[^A-Za-z0-9_]/_}"   # sanitize for Prom metric name
  prefix="${prefix##_}"; prefix="${prefix%%_}"
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
  before=$(wc -l <"$TMP_METRICS" || echo 0)

  awk -v prefix="${prefix}" '
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
  ' <"$out_file" >> "$TMP_METRICS"

  after=$(wc -l <"$TMP_METRICS" || echo 0)
  produced=$((after - before))
  echo "Collected ${produced} metrics lines from: $label" >&2

  rm -f "$err_file" "$out_file"
}

# Main collect calls
collect_and_format chassis
# collect_and_format chassis temps
# collect_and_format chassis fans
# collect_and_format chassis pwrsupplies
# collect_and_format chassis batteries
collect_and_format chassis processors
collect_and_format chassis memory
collect_and_format chassis nics
collect_and_format system summary
collect_and_format storage controller
collect_and_format storage vdisk
collect_and_format storage pdisk controller=0
collect_and_format storage battery

# Optional: smartctl health checks (best-effort)
collect_smart_health() {
  if [[ "$SMART_ENABLE" != "true" ]]; then
    echo "SMART collection disabled (SMART_ENABLE=${SMART_ENABLE})" >&2
    return
  fi
  if [[ ! -x "$SMARTCTL_BIN" ]]; then
    echo "smartctl not found; skipping SMART collection" >&2
    return
  fi

  echo "# HELP dell_smart_drive_health SMART overall health (1=PASSED,0=FAILED,-1=UNKNOWN)" >>"$TMP_METRICS"
  echo "# TYPE dell_smart_drive_health gauge" >>"$TMP_METRICS"
  echo "# HELP dell_smart_drive_info SMART drive identity (labels only)" >>"$TMP_METRICS"
  echo "# TYPE dell_smart_drive_info gauge" >>"$TMP_METRICS"

  for idx in $(seq 0 $((SMART_MAX_DRIVES - 1))); do
    local out err status
    out="$(mktemp /tmp/smart.out.XXXXXX)"
    err="$(mktemp /tmp/smart.err.XXXXXX)"

    # Use -iH for identity + overall health; timeout to avoid hangs
    set +e
    timeout 10 "$SMARTCTL_BIN" -iH -d "megaraid,${idx}" "$SMART_BASE_DEVICE" >"$out" 2>"$err"
    status=$?
    set -e

    if [[ $status -ne 0 ]]; then
      # Exit 2 usually means invalid device/index; stop scanning further
      if grep -qiE "Invalid .*megaraid|Unable to detect device|Open device failed" "$err" 2>/dev/null; then
        rm -f "$out" "$err"
        break
      fi
      echo "SMART probe failed for slot ${idx} (exit ${status})" >&2
      tail -n 10 "$err" >&2 || true
      rm -f "$out" "$err"
      continue
    fi

    # Extract fields
    local model serial fw health
    model="$(grep -E '^(Device Model|Product|Model Family)[[:space:]]*:' "$out" | head -n1 | cut -d: -f2- | xargs || true)"
    serial="$(grep -E '^Serial Number[[:space:]]*:' "$out" | head -n1 | cut -d: -f2- | xargs || true)"
    fw="$(grep -E '^(Firmware Version|Revision Number)[[:space:]]*:' "$out" | head -n1 | cut -d: -f2- | xargs || true)"
    health="$(grep -i 'overall-health self-assessment test result' "$out" | head -n1 | awk -F: '{gsub(/^[ \t]+/,"",$2); print $2}' || true)"

    local health_val=-1
    if echo "$health" | grep -qi "PASSED"; then
      health_val=1
    elif echo "$health" | grep -qi "FAILED"; then
      health_val=0
    fi

    local model_s serial_s fw_s
    model_s="$(sanitize_label "${model:-unknown}")"
    serial_s="$(sanitize_label "${serial:-unknown}")"
    fw_s="$(sanitize_label "${fw:-unknown}")"

    echo "smartctl slot ${idx}: model='${model}' serial='${serial}' fw='${fw}' health='${health}' (${health_val})" >&2

    cat >>"$TMP_METRICS" <<EOF
dell_smart_drive_info{controller="${SMART_CONTROLLER_ID}",slot="${idx}",device="$(sanitize_label "${SMART_BASE_DEVICE}")",model="${model_s}",serial="${serial_s}",firmware="${fw_s}"} 1
dell_smart_drive_health{controller="${SMART_CONTROLLER_ID}",slot="${idx}",device="$(sanitize_label "${SMART_BASE_DEVICE}")"} ${health_val}
EOF

    rm -f "$out" "$err"
  done
}

collect_smart_health

# Atomically replace the metrics file to avoid textfile parser seeing partial writes
mv "$TMP_METRICS" "$METRICS_FILE"
