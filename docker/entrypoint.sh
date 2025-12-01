#!/bin/bash
set -euo pipefail

AGENT_CONFIG="/etc/grafana-agent/agent.river"
OMREPORT="/opt/dell/srvadmin/bin/omreport"

# Inject Grafana credentials if placeholders are present (or fail fast if missing)
if grep -Eq "GRAFANA_API_KEY_PLACEHOLDER|REPLACE_ME|GRAFANA_USERNAME_PLACEHOLDER" "$AGENT_CONFIG"; then
  if [[ -z "${GRAFANA_API_KEY:-}" ]]; then
    echo "GRAFANA_API_KEY is required to talk to Grafana Cloud" >&2
    exit 1
  fi

  sed -i "s|GRAFANA_API_KEY_PLACEHOLDER|${GRAFANA_API_KEY}|g" "$AGENT_CONFIG"
  sed -i "s|REPLACE_ME|${GRAFANA_API_KEY}|g" "$AGENT_CONFIG"
  sed -i "s|GRAFANA_USERNAME_PLACEHOLDER|${GRAFANA_USERNAME:-2361797}|g" "$AGENT_CONFIG"
fi

if grep -Eq "GRAFANA_API_KEY_PLACEHOLDER|REPLACE_ME|GRAFANA_USERNAME_PLACEHOLDER" "$AGENT_CONFIG"; then
  echo "Grafana credentials placeholders are still present; refusing to start" >&2
  exit 1
fi

if [[ ! -x "$OMREPORT" ]]; then
  echo "omreport missing; OMSA installation failed" >&2
  exit 1
fi

# Require IPMI/SMBus devices from the host; bail with a clear message if missing.
if [[ ! -e /dev/ipmi0 && ! -e /dev/ipmi/0 ]]; then
  echo "ipmi devices not present in container; ensure host modules are loaded: modprobe dell_smbios i2c_i801 i2c_smbus ipmi_devintf ipmi_si" >&2
  echo "also run container with --privileged -v /dev:/dev -v /sys:/sys (rw for /dev)" >&2
  exit 1
fi

run_omreport_probe() {
  # Run omreport once and log success/failure with a small snippet
  local label=$1
  shift
  local probe_log
  probe_log="$(mktemp /tmp/omreport_probe.XXXXXX)"
  set +e
  "$OMREPORT" "$@" >"$probe_log" 2>&1
  local status=$?
  set -e

  if [[ $status -eq 0 ]]; then
    echo "OMSA probe ok: $label (omreport $*)" >&2
    head -n 10 "$probe_log" >&2 || true
  else
    echo "OMSA probe FAILED ($status): $label (omreport $*)" >&2
    echo "---- omreport stderr/stdout ----" >&2
    tail -n 40 "$probe_log" >&2 || true
    echo "--------------------------------" >&2
  fi
  rm -f "$probe_log"
}

# Start OMSA daemons directly (avoid DKS driver builds inside the container)
/opt/dell/srvadmin/sbin/dsm_sa_datamgrd &
/opt/dell/srvadmin/sbin/dsm_sa_eventmgrd &
/opt/dell/srvadmin/sbin/dsm_sa_snmpd &

# Give OMSA a moment to come up; do not hard-fail, but log readiness issues
OMSA_READY=false
for i in $(seq 1 10); do
  if /opt/dell/srvadmin/bin/omreport chassis >/dev/null 2>&1; then
    OMSA_READY=true
    break
  fi
  echo "Waiting for OMSA services to be ready (attempt $i/10)..." >&2
  sleep 2
done
if [[ "$OMSA_READY" != "true" ]]; then
  echo "OMSA not ready; collector may emit empty metrics until services come up." >&2
fi

# Run a few probes up front so the log contains useful diagnostics
run_omreport_probe "chassis summary" chassis
run_omreport_probe "chassis temps" chassis temps
run_omreport_probe "storage controller" storage controller

# Start collector in background loop
echo "Starting metrics collector loop..."
(
  while true; do
    /opt/dell-exporter/collect.sh || exit $?
    sleep 60
  done
) &

# Optional: Fluent Bit syslog receiver -> GCP Cloud Logging
ENABLE_SYSLOG_FORWARDING="${ENABLE_SYSLOG_FORWARDING:-false}"
SYSLOG_PORT="${SYSLOG_PORT:-5514}"
SYSLOG_MODE="${SYSLOG_MODE:-udp}" # udp or tcp
GCP_LOG_NAME="${GCP_LOG_NAME:-idrac-syslog}"
GCP_RESOURCE="${GCP_RESOURCE:-global}"

if [[ "$ENABLE_SYSLOG_FORWARDING" == "true" ]]; then
  # Resolve Fluent Bit binary in multiple expected locations
  FLUENT_BIT_BIN="${FLUENT_BIT_BIN:-}"
  if [[ -z "$FLUENT_BIT_BIN" ]]; then
    FLUENT_BIT_BIN="$(command -v fluent-bit || true)"
  fi
  if [[ -z "$FLUENT_BIT_BIN" && -x /opt/fluent-bit/bin/fluent-bit ]]; then
    FLUENT_BIT_BIN="/opt/fluent-bit/bin/fluent-bit"
  fi
  if [[ -z "$FLUENT_BIT_BIN" && -x /fluent-bit/bin/fluent-bit ]]; then
    FLUENT_BIT_BIN="/fluent-bit/bin/fluent-bit"
  fi

  if [[ -z "${GCP_PROJECT_ID:-}" ]]; then
    echo "ENABLE_SYSLOG_FORWARDING=true but GCP_PROJECT_ID is not set" >&2
    exit 1
  fi
  if [[ -z "${GOOGLE_APPLICATION_CREDENTIALS:-}" || ! -f "${GOOGLE_APPLICATION_CREDENTIALS}" ]]; then
    echo "GOOGLE_APPLICATION_CREDENTIALS must point to a readable service account JSON key" >&2
    exit 1
  fi
  if [[ -z "$FLUENT_BIT_BIN" ]]; then
    echo "Fluent Bit not found in image (PATH=$PATH or /fluent-bit/bin). Disabling syslog forwarding to keep service running; logs will NOT be forwarded." >&2
    ls -l /opt/fluent-bit/bin /fluent-bit/bin 2>/dev/null || true
    exit 1
  fi

  cat >/etc/fluent-bit/fluent-bit.conf <<EOF
[SERVICE]
    Flush        5
    Daemon       off
    Log_Level    info

[INPUT]
    Name   syslog
    Listen 0.0.0.0
    Port   ${SYSLOG_PORT}
    Mode   ${SYSLOG_MODE}
    Parser syslog-rfc3164

[FILTER]
    Name    modify
    Match   syslog.*
    Add     log_source idrac

[OUTPUT]
    Name        stackdriver
    Match       syslog.*
    resource    ${GCP_RESOURCE}
    log_name    ${GCP_LOG_NAME}
    project_id  ${GCP_PROJECT_ID}
    service_account_credentials ${GOOGLE_APPLICATION_CREDENTIALS}
EOF

  echo "Starting Fluent Bit syslog receiver on ${SYSLOG_MODE} port ${SYSLOG_PORT} -> GCP project ${GCP_PROJECT_ID}"
  "$FLUENT_BIT_BIN" -c /etc/fluent-bit/fluent-bit.conf &
fi

# Run Grafana Agent
exec /usr/bin/grafana-agent-flow run \
  --storage.path=/tmp/agent \
  --server.http.listen-addr=0.0.0.0:12345 \
  /etc/grafana-agent/agent.river
