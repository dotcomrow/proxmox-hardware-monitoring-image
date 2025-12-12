#!/bin/bash
# LST/SSV parser for omreport output.

collect_and_format() {
  local args=("$@")
  local label="${args[*]}"
  local prefix="${label// /_}"
  prefix="${prefix//[^A-Za-z0-9_]/_}"
  prefix="${prefix##_}"; prefix="${prefix%%_}"
  prefix="$(echo "$prefix" | tr '[:upper:]' '[:lower:]')"
  echo "Collecting: $label" >&2

  local err_file out_file
  err_file="$(mktemp /tmp/omsa_collect.err.XXXXXX)"
  out_file="$(mktemp /tmp/omsa_collect.out.XXXXXX)"

  set +e
  cmd=("$OMREPORT")
  cmd+=("${args[@]}")
  if [[ -n "$OMREPORT_FMT" ]]; then
    cmd+=(-fmt "$OMREPORT_FMT")
  fi
  "${cmd[@]}" >"$out_file" 2>"$err_file"
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
      line=$0
      delim=":"
      if (index(line,";")>0) delim=";"
      split(line, kv, delim)
      key = kv[1]
      value = kv[2]

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
