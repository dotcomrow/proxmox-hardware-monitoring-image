#!/bin/bash
set -euo pipefail

AGENT_CONFIG="/etc/grafana-agent/agent.river"
OMREPORT="/opt/dell/srvadmin/bin/omreport"
LOG_DIR="${LOG_DIR:-/var/log/dell-hardware-exporter}"
LOGROTATE_INTERVAL_SECONDS="${LOGROTATE_INTERVAL_SECONDS:-3600}"
LOGROTATE_STATE="${LOGROTATE_STATE:-/var/lib/logrotate/dell-hardware-exporter.status}"

case "$LOGROTATE_INTERVAL_SECONDS" in
  ''|*[!0-9]*) LOGROTATE_INTERVAL_SECONDS=3600 ;;
esac

mkdir -p "$LOG_DIR" "$(dirname "$LOGROTATE_STATE")"

start_logrotate_loop() {
  if ! command -v logrotate >/dev/null 2>&1; then
    echo "logrotate not found; container log files will not be rotated" >&2
    return
  fi

  (
    while true; do
      logrotate -s "$LOGROTATE_STATE" /etc/logrotate.d/dell-hardware-exporter \
        >>"${LOG_DIR}/logrotate.log" 2>&1 || true
      sleep "$LOGROTATE_INTERVAL_SECONDS"
    done
  ) &
}

# Inject Grafana credentials if placeholders are present (or fail fast if missing)
if grep -Eq "GRAFANA_API_KEY_PLACEHOLDER|REPLACE_ME|GRAFANA_USERNAME_PLACEHOLDER|PROM_REMOTE_AUTH_PLACEHOLDER" "$AGENT_CONFIG" /etc/otelcol/config.yaml 2>/dev/null; then
  # First, try to use pre-baked credentials already substituted in agent.river (build-time replacement)
  agent_user="$(awk -F'\"' '/username[ \t]*=/{print $2; exit}' "$AGENT_CONFIG" || true)"
  agent_pass="$(awk -F'\"' '/password[ \t]*=/{print $2; exit}' "$AGENT_CONFIG" || true)"

  # If not present, fall back to env-based sources
  if [[ -z "${agent_pass:-}" ]]; then
    if [[ -z "${GRAFANA_API_KEY:-}" ]]; then
      if [[ -n "${GRAFANA_SERVICE_ACCOUNT_TOKEN:-}" ]]; then
        GRAFANA_API_KEY="${GRAFANA_SERVICE_ACCOUNT_TOKEN}"
      elif [[ -n "${GRAFANA_TOKEN:-}" ]]; then
        GRAFANA_API_KEY="${GRAFANA_TOKEN}"
      fi
    fi
    agent_pass="${GRAFANA_API_KEY:-}"
  fi
  if [[ -z "${agent_user:-}" ]]; then
    agent_user="${GRAFANA_USERNAME:-2361797}"
  fi

  if [[ -n "${agent_pass:-}" ]]; then
    if command -v base64 >/dev/null 2>&1; then
      auth_b64="$(printf '%s:%s' "${agent_user}" "${agent_pass}" | base64 -w0)"
      sed -i "s|PROM_REMOTE_AUTH_PLACEHOLDER|${auth_b64}|g" "$AGENT_CONFIG"
      sed -i "s|PROM_REMOTE_AUTH_PLACEHOLDER|${auth_b64}|g" /etc/otelcol/config.yaml || true
    else
      echo "base64 not found; cannot populate OTLP remote_write auth header" >&2
    fi

    sed -i "s|GRAFANA_API_KEY_PLACEHOLDER|${agent_pass}|g" "$AGENT_CONFIG"
    sed -i "s|REPLACE_ME|${agent_pass}|g" "$AGENT_CONFIG"
    sed -i "s|GRAFANA_USERNAME_PLACEHOLDER|${agent_user}|g" "$AGENT_CONFIG"
  else
    echo "Warning: no Grafana credentials found for replacement (agent.river or env)." >&2
  fi
fi

# Log if auth placeholder remains
if grep -q "PROM_REMOTE_AUTH_PLACEHOLDER" /etc/otelcol/config.yaml 2>/dev/null; then
  echo "Warning: PROM_REMOTE_AUTH_PLACEHOLDER still present in /etc/otelcol/config.yaml (missing Grafana creds?)" >&2
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
if ! ls /dev/i2c-* >/dev/null 2>&1; then
  echo "i2c devices not visible in container; temperature/fan probes may be unavailable. Ensure i2c_i801 and i2c_smbus are loaded and /dev is passed through." >&2
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
find /opt/dell/srvadmin/var/run -maxdepth 1 -name "*.pid" -type f -delete 2>/dev/null || true
/opt/dell/srvadmin/sbin/dsm_om_shrsvcd >>"${LOG_DIR}/dsm_om_shrsvcd.log" 2>&1 &
/opt/dell/srvadmin/sbin/dsm_om_connsvcd -run >>"${LOG_DIR}/dsm_om_connsvcd.log" 2>&1 &
/opt/dell/srvadmin/sbin/dsm_sa_eventmgrd >>"${LOG_DIR}/dsm_sa_eventmgrd.log" 2>&1 &
/opt/dell/srvadmin/sbin/dsm_sa_datamgrd >>"${LOG_DIR}/dsm_sa_datamgrd.log" 2>&1 &
/opt/dell/srvadmin/sbin/dsm_sa_snmpd >>"${LOG_DIR}/dsm_sa_snmpd.log" 2>&1 &

start_logrotate_loop

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
run_omreport_probe "storage controller" storage controller

# Start ipmi_exporter (local /dev/ipmi0 -> Prometheus metrics on 127.0.0.1:9290)
/usr/local/bin/ipmi_exporter \
  --config.file=/etc/ipmi_exporter.yml \
  --web.listen-address=:9290 \
  >>"${LOG_DIR}/ipmi_exporter.log" 2>&1 &

# Start collector in background loop
echo "Starting metrics collector loop..."
(
  while true; do
    /opt/dell-exporter/collect.sh || exit $?
    sleep 60
  done
) >>"${LOG_DIR}/collector.log" 2>&1 &

# Start OTLP -> remote_write bridge (otelcol-contrib)
/usr/bin/otelcol-contrib --config /etc/otelcol/config.yaml >>"${LOG_DIR}/otelcol.log" 2>&1 &

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
    Parsers_File /etc/fluent-bit/parsers.conf

[INPUT]
    Name   syslog
    Listen 0.0.0.0
    Port   ${SYSLOG_PORT}
    Mode   ${SYSLOG_MODE}
    Parser syslog-rfc5424
    Tag    syslog

[FILTER]
    Name    modify
    Match   syslog*
    Add     log_source idrac

[OUTPUT]
    Name        stackdriver
    Match       syslog*
    resource    ${GCP_RESOURCE}
    tag_prefix  ${GCP_LOG_NAME}
    export_to_project_id  ${GCP_PROJECT_ID}
    google_service_credentials ${GOOGLE_APPLICATION_CREDENTIALS}
EOF

  echo "Starting Fluent Bit syslog receiver on ${SYSLOG_MODE} port ${SYSLOG_PORT} -> GCP project ${GCP_PROJECT_ID}"
  "$FLUENT_BIT_BIN" -c /etc/fluent-bit/fluent-bit.conf >>"${LOG_DIR}/fluent-bit.log" 2>&1 &
fi

# Run Grafana Agent
exec /usr/bin/grafana-agent-flow run \
  --storage.path=/tmp/agent \
  --server.http.listen-addr=0.0.0.0:12345 \
  /etc/grafana-agent/agent.river \
  >>"${LOG_DIR}/grafana-agent.log" 2>&1
