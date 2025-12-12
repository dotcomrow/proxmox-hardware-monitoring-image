#!/bin/bash
set -euo pipefail

METRICS_FILE="/opt/dell-exporter/metrics.prom"
OMREPORT="/opt/dell/srvadmin/bin/omreport"
TMP_METRICS="$(mktemp /opt/dell-exporter/metrics.prom.tmp.XXXXXX)"
trap 'rm -f "$TMP_METRICS"' EXIT
SMARTCTL_BIN="${SMARTCTL_BIN:-/usr/sbin/smartctl}"
OMREPORT_FMT_RAW="${OMREPORT_FMT:-${OMREPORT_OUTPUT_FORMAT:-ssv}}"
OMREPORT_FMT_CANON="$(echo "$OMREPORT_FMT_RAW" | tr '[:upper:]' '[:lower:]' | xargs)"
# Accept common values; fallback to lst if unknown
case "$OMREPORT_FMT_CANON" in
  xml|lst|ssv) ;;
  *) OMREPORT_FMT_CANON="lst" ;;
esac
OMREPORT_COMMANDS="${OMREPORT_COMMANDS:-}"
SMART_BASE_DEVICE="${SMART_BASE_DEVICE:-/dev/sda}"
SMART_MAX_DRIVES="${SMART_MAX_DRIVES:-6}"
SMART_ENABLE="${SMART_ENABLE:-true}"
SMART_CONTROLLER_ID="${SMART_CONTROLLER_ID:-0}"
SMART_DRIVER="${SMART_DRIVER:-sat+megaraid}"
SMART_DRIVER_FALLBACKS="${SMART_DRIVER_FALLBACKS:-megaraid}"
SMART_EXTRA_DEVICES="${SMART_EXTRA_DEVICES:-}"
SMART_EXTRA_DRIVER="${SMART_EXTRA_DRIVER:-auto}"
IPMI_SPLIT_SOURCE="${IPMI_SPLIT_SOURCE:-http://127.0.0.1:9290/metrics}"
# Default list of devices to collect SMART from (space-separated)
SMART_DEVICE_LIST="${SMART_DEVICE_LIST:-/dev/sda /dev/sdb /dev/sdc}"

if [[ ! -x "$OMREPORT" ]]; then
  echo "omreport not found!" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=collect_lib.sh
. "${SCRIPT_DIR}/collect_lib.sh"

# Load format-specific parser
case "${OMREPORT_FMT_CANON}" in
  xml)
    # shellcheck source=collect_lib_xml.sh
    . "${SCRIPT_DIR}/collect_lib_xml.sh"
    echo "OMREPORT output format: xml (raw='${OMREPORT_FMT_RAW}')" >&2
    ;;
  *)
    # shellcheck source=collect_lib_lst.sh
    . "${SCRIPT_DIR}/collect_lib_lst.sh"
    echo "OMREPORT output format: ${OMREPORT_FMT_CANON} (raw='${OMREPORT_FMT_RAW}')" >&2
    ;;
esac

true > "$TMP_METRICS"

load_default_commands() {
  cat <<'EOF'
chassis
chassis biossetup
chassis processors
chassis memory
chassis fans
chassis temps
chassis pwrsupplies
chassis nics
chassis backplane
chassis frontpanel
chassis intrusion
chassis leds
chassis lcd
system summary
system alertlog
storage controller
storage vdisk
storage pdisk controller=0
storage pdisk controller=1
storage battery
storage enclosure
storage cachecade
storage channel
storage service
remoteaccess
EOF
}

if [[ -n "$OMREPORT_COMMANDS" ]]; then
  # Allow newline-separated list via env
  IFS=$'\n' read -r -d '' -a OM_CMDS <<<"$(printf "%s\0" "$OMREPORT_COMMANDS")"
else
  IFS=$'\n' read -r -d '' -a OM_CMDS <<<"$(load_default_commands; printf '\0')"
fi

for cmd in "${OM_CMDS[@]}"; do
  [[ -z "$cmd" ]] && continue
  # shellword-split safely: treat command as words
  read -r -a parts <<<"$cmd"
  collect_and_format "${parts[@]}"
done

collect_smart_health
collect_ipmi_split

mv "$TMP_METRICS" "$METRICS_FILE"
