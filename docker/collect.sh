#!/bin/bash
set -euo pipefail

METRICS_FILE="/opt/dell-exporter/metrics.prom"
OMREPORT="/opt/dell/srvadmin/bin/omreport"
TMP_METRICS="$(mktemp /opt/dell-exporter/metrics.prom.tmp.XXXXXX)"
trap 'rm -f "$TMP_METRICS"' EXIT
SMARTCTL_BIN="${SMARTCTL_BIN:-/usr/sbin/smartctl}"
SMART_BASE_DEVICE="${SMART_BASE_DEVICE:-/dev/sda}"
SMART_MAX_DRIVES="${SMART_MAX_DRIVES:-6}"
SMART_ENABLE="${SMART_ENABLE:-true}"
SMART_CONTROLLER_ID="${SMART_CONTROLLER_ID:-0}"

if [[ ! -x "$OMREPORT" ]]; then
  echo "omreport not found!" >&2
  exit 1
fi

# Start fresh metrics into a temp file (atomic move at the end avoids partial reads)
true > "$TMP_METRICS"

sanitize_label() {
  local val="$1"
  # Replace unsafe chars with underscore
  val="${val//[^A-Za-z0-9_]/_}"
  val="${val##_}"; val="${val%%_}"
  echo "$val"
}

emit_metric() {
  local name="$1"
  local labels="$2"
  local value="$3"
  printf '%s{%s} %s\n' "$name" "$labels" "$value" >> "$TMP_METRICS"
}

collect_and_format() {
  # Accept the full omreport command as arguments (e.g. chassis temps)
  local args=("$@")
  local label="${args[*]}"
  local prefix="${label// /_}"
  prefix="${prefix//[^A-Za-z0-9_]/_}"   # sanitize for Prom metric name
  prefix="${prefix##_}"; prefix="${prefix%%_}"
  prefix="$(echo "$prefix" | tr '[:upper:]' '[:lower:]')"
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
    /^[A-Za-z]/ {
      gsub(/\r/, "")
      split($0, kv, ":")
      key = kv[1]
      value = kv[2]

      # Cleanup key and value
      gsub(/^[ \t]+|[ \t]+$/, "", key)
      gsub(/[^a-zA-Z0-9_]/, "_", key)
      gsub(/^_+|_+$/, "", key)
      key = tolower(key)
      gsub(/^[ \t]+|[ \t]+$/, "", value)

      if (value ~ /^-?[0-9]+(\.[0-9]+)?$/ && key != "") {
        metric_name = "dell_" prefix "_" key
        gsub(/__+/, "_", metric_name)
        gsub(/^_+|_+$/, "", metric_name)
        printf "%s %s\n", metric_name, value
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

  for idx in $(seq 0 $((SMART_MAX_DRIVES - 1))); do
    local out err status
    out="$(mktemp /tmp/smart.out.XXXXXX)"
    err="$(mktemp /tmp/smart.err.XXXXXX)"

    # Use full -a to gather attributes; timeout to avoid hangs
    set +e
    timeout 15 "$SMARTCTL_BIN" -a -d "megaraid,${idx}" "$SMART_BASE_DEVICE" >"$out" 2>"$err"
    status=$?
    set -e

    if [[ $status -ne 0 ]]; then
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

    emit_metric "dell_smart_drive_info" "controller=\"${SMART_CONTROLLER_ID}\",slot=\"${idx}\",device=\"$(sanitize_label "${SMART_BASE_DEVICE}")\",model=\"${model_s}\",serial=\"${serial_s}\",firmware=\"${fw_s}\"" 1
    emit_metric "dell_smart_drive_health" "controller=\"${SMART_CONTROLLER_ID}\",slot=\"${idx}\",device=\"$(sanitize_label "${SMART_BASE_DEVICE}")\"" "${health_val}"

    # Per-attribute metrics from SMART attribute table (SATA) and selected SAS counters
    awk -v ctrl="${SMART_CONTROLLER_ID}" -v slot="${idx}" -v dev="$(sanitize_label "${SMART_BASE_DEVICE}")" '
      function sanitize(s) { gsub(/[^A-Za-z0-9_]/,"_",s); s=tolower(s); gsub(/^_+|_+$/,"",s); return s }
      # SATA attribute table
      $1 ~ /^[0-9]+$/ && $2 ~ /[A-Za-z0-9_-]/ && $(NF) ~ /[0-9]/ {
        id = $1
        attr = sanitize($2)
        raw = $(NF)
        sub(/\(.*/, "", raw)
        gsub(/[^0-9.\-]/, "", raw)
        if (raw == "" || attr == "") next
        printf "dell_smart_attr_raw{controller=\"%s\",slot=\"%s\",device=\"%s\",id=\"%s\",attribute=\"%s\"} %s\n", ctrl, slot, dev, id, attr, raw
      }
      # SAS-style counters
      /(Non-medium error count|grown defect list|Elements in grown defect list)/ {
        val=$NF; gsub(/[^0-9.\-]/,"",val); if(val=="") next;
        key=sanitize($0); printf "dell_smart_attr_raw{controller=\"%s\",slot=\"%s\",device=\"%s\",id=\"sas\",attribute=\"%s\"} %s\n", ctrl, slot, dev, key, val
      }
    ' "$out" >>"$TMP_METRICS"

    # Temperature if present
    temp_c=$(awk '
      /Current Drive Temperature:/ {for(i=1;i<=NF;i++) if($i ~ /^[0-9]+$/ && $(i+1) ~ /^C/) {print $i; exit}}
      /Drive Temperature:/ {for(i=1;i<=NF;i++) if($i ~ /^[0-9]+$/ && $(i+1) ~ /^C/) {print $i; exit}}
      /Temperature_Celsius/ && $1 ~ /^[0-9]+$/ {print $NF; exit}
    ' "$out")
    if [[ -n "$temp_c" ]]; then
      emit_metric "dell_smart_temp_c" "controller=\"${SMART_CONTROLLER_ID}\",slot=\"${idx}\",device=\"$(sanitize_label "${SMART_BASE_DEVICE}")\"" "$temp_c"
    fi

    rm -f "$out" "$err"
  done
}

collect_smart_health

# Atomically replace the metrics file to avoid textfile parser seeing partial writes
mv "$TMP_METRICS" "$METRICS_FILE"
