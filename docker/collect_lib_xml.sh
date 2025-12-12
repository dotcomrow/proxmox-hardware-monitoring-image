#!/bin/bash
# XML parser for omreport output.

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

  if ! command -v python3 >/dev/null 2>&1; then
    echo "⚠️ python3 not found; cannot parse XML output for $label" >&2
    return
  fi

  set +e
  cmd=("$OMREPORT")
  cmd+=("${args[@]}")
  cmd+=(-fmt xml)
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

  python3 - "$out_file" "$prefix" >>"$TMP_METRICS" <<'PYCODE'
import re
import sys
import xml.etree.ElementTree as ET

fname, prefix = sys.argv[1], sys.argv[2]
try:
    tree = ET.parse(fname)
    root = tree.getroot()
except Exception as e:
    sys.stderr.write(f"xml parse error: {e}\n")
    sys.exit(0)

num_re = re.compile(r"^-?[0-9]+(\.[0-9]+)?$")

def sanitize(s: str) -> str:
    return re.sub(r"_+", "_", re.sub(r"[^A-Za-z0-9_]", "_", s)).strip("_").lower()

def labels_to_str(labels):
    parts=[]
    for k in sorted(labels):
        v=str(labels[k]).replace('"','')
        parts.append(f'{k}="{v}"')
    return ",".join(parts)

def emit(metric, labels, value):
    print(f"{metric}{{{labels_to_str(labels)}}} {value}")

def process_list(list_node):
    list_name = sanitize(list_node.tag)
    list_name = re.sub(r"_list$", "", list_name)
    base_metric = f"dell_omreport_{list_name or 'root'}"
    rows = list(list_node)
    for idx, row in enumerate(rows):
        attrs = {k.lower(): v for k,v in row.attrib.items()}
        row_id = attrs.get("index") or attrs.get("extname") or attrs.get("id") or attrs.get("oid") or str(idx)
        base_labels = {"row": row_id}
        if attrs.get("extname"):
            base_labels["extname"] = sanitize(attrs["extname"])
        def walk(node, path):
            children = list(node)
            tag = sanitize(node.tag)
            cur_path = path+[tag] if tag else path
            text = (node.text or "").strip()
            unit = node.attrib.get("unit","")
            if text:
                if num_re.match(text):
                    labels = dict(base_labels)
                    labels["path"] = "_".join(cur_path)
                    if unit:
                        labels["unit"] = unit
                    emit(base_metric, labels, text)
                else:
                    labels = dict(base_labels)
                    labels["path"] = "_".join(cur_path)
                    labels["text"] = text
                    emit(base_metric+"_info", labels, 1)
            for child in children:
                walk(child, cur_path)
        walk(row, [])

lists = [n for n in root.iter() if n.tag.endswith("List")]
if not lists:
    lists = [root]
for lst in lists:
    process_list(lst)
PYCODE

  after=$(wc -l <"$TMP_METRICS" || echo 0)
  produced=$((after - before))
  echo "Collected ${produced} metrics lines from: $label" >&2

  rm -f "$err_file" "$out_file"
}
