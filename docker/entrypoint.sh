#!/bin/bash
set -euo pipefail

AGENT_CONFIG="/etc/grafana-agent/agent.river"

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

if [[ ! -x /opt/dell/srvadmin/bin/omreport ]]; then
  echo "omreport missing; OMSA installation failed" >&2
  exit 1
fi

/opt/dell/srvadmin/sbin/dsm_sa_datamgrd &
/opt/dell/srvadmin/sbin/dsm_sa_eventmgrd &
/opt/dell/srvadmin/sbin/dsm_sa_snmpd &

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
  if [[ -z "${GCP_PROJECT_ID:-}" ]]; then
    echo "ENABLE_SYSLOG_FORWARDING=true but GCP_PROJECT_ID is not set" >&2
    exit 1
  fi
  if [[ -z "${GOOGLE_APPLICATION_CREDENTIALS:-}" || ! -f "${GOOGLE_APPLICATION_CREDENTIALS}" ]]; then
    echo "GOOGLE_APPLICATION_CREDENTIALS must point to a readable service account JSON key" >&2
    exit 1
  fi
  if ! command -v fluent-bit >/dev/null 2>&1; then
    echo "Fluent Bit is not installed; cannot forward syslog" >&2
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
  fluent-bit -c /etc/fluent-bit/fluent-bit.conf &
fi

# Run Grafana Agent
exec /usr/bin/grafana-agent-flow run \
  --storage.path=/tmp/agent \
  --server.http.listen-addr=0.0.0.0:12345 \
  /etc/grafana-agent/agent.river
