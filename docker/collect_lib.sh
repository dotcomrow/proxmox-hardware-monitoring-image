#!/bin/bash
# Shared helpers for OMSA/IPMI/SMART collection. Sourced by collect.sh.

sanitize_label() {
  local val="$1"
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

first_numeric() {
  local s="$*"
  if [[ $s =~ (-?[0-9]+(\.[0-9]+)?) ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  else
    printf ''
  fi
}

# SMART collection: emit grouped table-style metrics per device
collect_smart_health() {
  if [[ "$SMART_ENABLE" != "true" ]]; then
    echo "SMART collection disabled (SMART_ENABLE=${SMART_ENABLE})" >&2
    return
  fi
  if [[ ! -x "$SMARTCTL_BIN" ]]; then
    echo "smartctl not found; skipping SMART collection" >&2
    return
  fi

  run_smart_probe() {
    local base_dev="$1" slot="$2" driver_list="$3" ctrl_id="$4"
    local base_label
    base_label="$(sanitize_label "$base_dev")"
    local out err status
    out="$(mktemp /tmp/smart.out.XXXXXX)"
    err="$(mktemp /tmp/smart.err.XXXXXX)"

    local success=0 drv_used=""
    IFS=',' read -r -a drv_list_arr <<<"$driver_list"
    for drv in "${drv_list_arr[@]}"; do
      drv="$(echo "$drv" | xargs)"
      [[ -z "$drv" ]] && continue
      set +e
      if [[ -n "$slot" ]]; then
        timeout 15 "$SMARTCTL_BIN" -a -d "${drv},${slot}" "$base_dev" >"$out" 2>"$err"
      else
        timeout 15 "$SMARTCTL_BIN" -a -d "${drv}" "$base_dev" >"$out" 2>"$err"
      fi
      status=$?
      set -e
      if grep -qiE "Open device failed|Unable to detect device|No such device" "$err" 2>/dev/null; then
        continue
      fi
      if [[ -s "$out" ]]; then
        success=1
        drv_used="$drv"
        break
      fi
    done

    if [[ $success -ne 1 ]]; then
      echo "SMART probe failed for ${base_dev} slot ${slot:-direct} (drivers tried: ${driver_list}) last exit ${status}" >&2
      tail -n 10 "$err" >&2 || true
      rm -f "$out" "$err"
      return
    fi
    echo "SMART probe ${base_dev} slot ${slot:-direct} succeeded with driver ${drv_used} (exit ${status})" >&2

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

    local model_s serial_s fw_s slot_label
    model_s="$(sanitize_label "${model:-unknown}")"
    serial_s="$(sanitize_label "${serial:-unknown}")"
    fw_s="$(sanitize_label "${fw:-unknown}")"
    slot_label="$(sanitize_label "${slot:-direct}")"
    local table_metric="smart_data_${base_label}"
    local info_metric="${table_metric}_info"

    printf "%s{device=\"%s\",slot=\"%s\",driver=\"%s\",id=\"health\",attribute=\"health\",field=\"value\"} %s\n" "$table_metric" "$base_label" "$slot_label" "$drv_used" "${health_val}" >>"$TMP_METRICS"
    printf "%s{device=\"%s\",slot=\"%s\",driver=\"%s\",id=\"model\",attribute=\"model\",field=\"text\",text=\"%s\"} 1\n" "$info_metric" "$base_label" "$slot_label" "$drv_used" "$model" >>"$TMP_METRICS"
    printf "%s{device=\"%s\",slot=\"%s\",driver=\"%s\",id=\"serial\",attribute=\"serial\",field=\"text\",text=\"%s\"} 1\n" "$info_metric" "$base_label" "$slot_label" "$drv_used" "$serial" >>"$TMP_METRICS"
    printf "%s{device=\"%s\",slot=\"%s\",driver=\"%s\",id=\"firmware\",attribute=\"firmware\",field=\"text\",text=\"%s\"} 1\n" "$info_metric" "$base_label" "$slot_label" "$drv_used" "$fw" >>"$TMP_METRICS"

    awk -v table="${table_metric}" -v info="${info_metric}" -v slot="${slot_label}" -v dev="${base_label}" -v driver="${drv_used}" '
      function sanitize(s) { gsub(/[^A-Za-z0-9_]/,"_",s); s=tolower(s); gsub(/^_+|_+$/,"",s); return s }
      $1 ~ /^[0-9]+$/ && $2 ~ /[A-Za-z0-9_-]/ {
        id = $1
        attr = sanitize($2)
        flag = $(3)
        value = $(4)
        worst = $(5)
        thresh = $(6)
        type_f = $(7)
        updated = $(8)
        when_failed = $(9)
        raw = ""
        for (i=10; i<=NF; i++) {
          token=$i
          if (token ~ /[0-9]/) {
            if (token ~ /[0-9]-[0-9]/) { split(token,parts,"-"); token=parts[1] }
            if (token ~ /\//) { split(token,parts,"/"); token=parts[1] }
            gsub(/[^0-9.\-]/, "", token)
            if (token == "") continue
            raw=token
            break
          }
        }
        if (attr == "") next
        if (value ~ /^[0-9]+$/) {
          printf "%s{device=\"%s\",slot=\"%s\",driver=\"%s\",id=\"%s\",attribute=\"%s\",field=\"value\"} %s\n", table, dev, slot, driver, id, attr, value
        }
        if (worst ~ /^[0-9]+$/) {
          printf "%s{device=\"%s\",slot=\"%s\",driver=\"%s\",id=\"%s\",attribute=\"%s\",field=\"worst\"} %s\n", table, dev, slot, driver, id, attr, worst
        }
        if (thresh ~ /^[0-9]+$/) {
          printf "%s{device=\"%s\",slot=\"%s\",driver=\"%s\",id=\"%s\",attribute=\"%s\",field=\"thresh\"} %s\n", table, dev, slot, driver, id, attr, thresh
        }
        if (raw != "") {
          printf "%s{device=\"%s\",slot=\"%s\",driver=\"%s\",id=\"%s\",attribute=\"%s\",field=\"raw\"} %s\n", table, dev, slot, driver, id, attr, raw
        }
        printf "%s{device=\"%s\",slot=\"%s\",driver=\"%s\",id=\"%s\",attribute=\"%s\",field=\"flag\",text=\"%s\"} 1\n", info, dev, slot, driver, id, attr, flag
        if (type_f != "") printf "%s{device=\"%s\",slot=\"%s\",driver=\"%s\",id=\"%s\",attribute=\"%s\",field=\"type\",text=\"%s\"} 1\n", info, dev, slot, driver, id, attr, type_f
        if (updated != "") printf "%s{device=\"%s\",slot=\"%s\",driver=\"%s\",id=\"%s\",attribute=\"%s\",field=\"updated\",text=\"%s\"} 1\n", info, dev, slot, driver, id, attr, updated
        if (when_failed != "") printf "%s{device=\"%s\",slot=\"%s\",driver=\"%s\",id=\"%s\",attribute=\"%s\",field=\"when_failed\",text=\"%s\"} 1\n", info, dev, slot, driver, id, attr, when_failed
      }
      /(Non-medium error count|grown defect list|Elements in grown defect list)/ {
        val=$NF; gsub(/[^0-9.\-]/,"",val); if(val=="") next;
        key=sanitize($0);
        printf "%s{device=\"%s\",slot=\"%s\",driver=\"%s\",id=\"sas\",attribute=\"%s\",field=\"raw\"} %s\n", table, dev, slot, driver, key, val
      }
    ' "$out" >>"$TMP_METRICS"

    temp_c=$(awk '
      function clean(tok) {
        if (tok ~ /[0-9]-[0-9]/) { split(tok,a,"-"); tok=a[1] }
        else if (tok ~ /[0-9]\/[0-9]/) { split(tok,a,"/"); tok=a[1] }
        gsub(/[^0-9.\-]/,"",tok)
        return tok
      }
      /(Current Drive Temperature:|Drive Temperature:|Temperature_Celsius)/ {
        for (i=1; i<=NF; i++) {
          if ($i ~ /[0-9]/) {
            val = clean($i)
            if (val != "") { print val; exit }
          }
        }
      }
    ' "$out")
    if [[ -n "$temp_c" ]]; then
      temp_c="$(first_numeric "$temp_c")"
      if [[ -n "$temp_c" ]]; then
        printf "%s{device=\"%s\",slot=\"%s\",driver=\"%s\",id=\"temp\",attribute=\"temp_c\",field=\"value\"} %s\n" "$table_metric" "$base_label" "$slot_label" "$drv_used" "$temp_c" >>"$TMP_METRICS"
      fi
    fi

    rm -f "$out" "$err"
  }

  local devices="${SMART_DEVICE_LIST:-${SMART_BASE_DEVICE:-/dev/sda}}"
  for base_dev in $devices; do
    if [[ "$base_dev" == "${SMART_BASE_DEVICE:-/dev/sda}" ]]; then
      for idx in $(seq 0 $((SMART_MAX_DRIVES - 1))); do
        run_smart_probe "$base_dev" "$idx" "${SMART_DRIVER},${SMART_DRIVER_FALLBACKS}" "${SMART_CONTROLLER_ID}"
      done
    else
      run_smart_probe "$base_dev" "" "${SMART_EXTRA_DRIVER:-auto}" "extra"
    fi
  done
}

# IPMI per-sensor fan-out plus grouped tables
collect_ipmi_split() {
  local src="${IPMI_SPLIT_SOURCE}"
  local out err before after produced
  out="$(mktemp /tmp/ipmi_split.out.XXXXXX)"
  err="$(mktemp /tmp/ipmi_split.err.XXXXXX)"

  if ! wget -qO "$out" "$src" 2>"$err"; then
    echo "ipmi_split: failed to scrape ${src}; ipmi_exporter not ready? ($(tail -n1 "$err" || true))" >&2
    rm -f "$out" "$err"
    return
  fi

  before=$(wc -l <"$TMP_METRICS" || echo 0)
  awk '
    function sanitize(s) { gsub(/[^A-Za-z0-9_]/,"_",s); s=tolower(s); gsub(/^_+|_+$/,"",s); gsub(/_+/,"_",s); return s }
    function parse_labels(str, kv,   n,i,part,key,val) {
      n = split(str, partlist, ",")
      for (i=1; i<=n; i++) {
        part=partlist[i]
        split(part, kvpair, "=")
        key=kvpair[1]; val=kvpair[2]
        gsub(/^[ \t]+|[ \t]+$/, "", key)
        gsub(/^[ \t]+|[ \t]+$/, "", val)
        gsub(/^"/, "", val); gsub(/"$/, "", val)
        kv[key]=val
      }
    }
    /^ipmi_sensor_value\{/ {
      label_str=$0
      sub(/^ipmi_sensor_value\{/,"",label_str)
      sub(/\}[ \t]+.*/,"",label_str)
      delete kv
      parse_labels(label_str, kv)
      name=kv["name"]
      if (name == "") next
      metric= sanitize(name)
      if (metric == "") next
      val=$NF; gsub(/^[ \t]+|[ \t]+$/, "", val)
      if (val !~ /^-?[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?$/) next
      unit=(("unit" in kv && kv["unit"]!="") ? kv["unit"] : (("type" in kv)?kv["type"]:""))
      printf "ipmi_sensor_%s{sensor=\"%s\",unit=\"%s\"} %s\n", metric, name, unit, val
      lname=tolower(name); lunit=tolower(unit)
      group="sensors"
      if (lunit ~ /rpm/ || lname ~ /fan/) group="fans"
      else if (lunit ~ /deg/ || lname ~ /temp/) group="temps"
      else if (lunit ~ /volt/) group="volts"
      else if (lunit ~ /amp/) group="amps"
      else if (lunit ~ /watt/) group="power"
      printf "ipmi_%s{sensor=\"%s\",unit=\"%s\"} %s\n", group, name, unit, val
      next
    }
    /^ipmi_sensor_state\{/ {
      label_str=$0
      sub(/^ipmi_sensor_state\{/,"",label_str)
      sub(/\}[ \t]+.*/,"",label_str)
      delete kv
      parse_labels(label_str, kv)
      name=kv["name"]; state=kv["state"]
      if (name == "") next
      if (state == "" && ("health" in kv) && kv["health"]!="") { state=kv["health"] }
      if (state == "") next
      metric= sanitize(name); s_state=sanitize(state)
      if (metric == "" || s_state == "") next
      val=$NF; gsub(/^[ \t]+|[ \t]+$/, "", val)
      if (val !~ /^-?[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?$/) next
      printf "ipmi_sensor_%s_state_%s{sensor=\"%s\",state=\"%s\"} %s\n", metric, s_state, name, state, val
      next
    }
    /^ipmi_[a-zA-Z0-9_]+\{/ {
      if (match($0, /^([a-zA-Z0-9_:]+)\{/, m) != 1) next
      base=m[1]
      label_str=$0
      sub(/^[^{]*\{/,"",label_str)
      sub(/\}[ \t]+.*/,"",label_str)
      delete kv
      parse_labels(label_str, kv)
      if (!("name" in kv)) next
      name=kv["name"]
      delete kv["name"]
      if (name == "") next
      val=$NF; gsub(/^[ \t]+|[ \t]+$/, "", val)
      if (val !~ /^-?[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?$/) next
      metric = sanitize(base)
      sensor = sanitize(name)
      if (metric == "" || sensor == "") next
      out_labels=""
      for (k in kv) {
        v=kv[k]; gsub(/"/,"",v)
        if (out_labels == "") out_labels = sprintf("%s=\"%s\"", k, v)
        else out_labels = sprintf("%s,%s=\"%s\"", out_labels, k, v)
      }
      if (out_labels == "") printf "%s_%s %s\n", metric, sensor, val
      else printf "%s_%s{%s} %s\n", metric, sensor, out_labels, val
      next
    }
  ' "$out" >>"$TMP_METRICS"

  after=$(wc -l <"$TMP_METRICS" || echo 0)
  produced=$((after - before))
  echo "Collected ${produced} ipmi per-sensor fan-out metrics from ${src}" >&2

  rm -f "$out" "$err"
}

# Generic fan-out: duplicate metrics with common labels into name-encoded series
fan_out_metrics() {
  local in="$TMP_METRICS"
  local out
  out="$(mktemp /tmp/metrics.fanout.XXXXXX)"

  awk '
    function sanitize(s) { gsub(/[^A-Za-z0-9_]/,"_",s); s=tolower(s); gsub(/^_+|_+$/,"",s); gsub(/_+/,"_",s); return s }
    function parse_labels(str, kv,   n,i,part,key,val) {
      n = split(str, partlist, ",")
      for (i=1; i<=n; i++) {
        part=partlist[i]
        split(part, kvpair, "=")
        key=kvpair[1]; val=kvpair[2]
        gsub(/^[ \t]+|[ \t]+$/, "", key)
        gsub(/^[ \t]+|[ \t]+$/, "", val)
        gsub(/^"/, "", val); gsub(/"$/, "", val)
        kv[key]=val
      }
    }
    /^[^#].*\{/ {
      if (match($0, /^([A-Za-z0-9_:]+)\{([^}]*)\}[ \t]+([-+0-9.eE]+)/, m) != 3) { print $0; next }
      metric=m[1]; label_str=m[2]; val=m[3]
      print $0
      delete kv
      parse_labels(label_str, kv)
      suffix=""
      if ("slot" in kv)       suffix = suffix "_slot_" sanitize(kv["slot"])
      if ("controller" in kv) suffix = suffix "_ctrl_" sanitize(kv["controller"])
      if ("device" in kv)     suffix = suffix "_dev_" sanitize(kv["device"])
      if ("sensor" in kv)     suffix = suffix "_sensor_" sanitize(kv["sensor"])
      if ("name" in kv)       suffix = suffix "_name_" sanitize(kv["name"])
      if ("attribute" in kv)  suffix = suffix "_attr_" sanitize(kv["attribute"])
      if ("id" in kv)         suffix = suffix "_id_" sanitize(kv["id"])

      if (suffix != "") {
        out_labels=""
        for (k in kv) {
          if (k=="controller" || k=="slot" || k=="device" || k=="sensor" || k=="name" || k=="attribute" || k=="id") continue
          v=kv[k]; gsub(/"/,"",v)
          if (out_labels == "") out_labels = sprintf("%s=\"%s\"", k, v)
          else out_labels = sprintf("%s,%s=\"%s\"", out_labels, k, v)
        }
        new_metric = metric suffix
        if (out_labels == "") printf "%s %s\n", new_metric, val >> "'"$out"'"
        else printf "%s{%s} %s\n", new_metric, out_labels, val >> "'"$out"'"
      }
      next
    }
    { print $0 }
  ' "$in" >"$out"

  mv "$out" "$TMP_METRICS"
}
