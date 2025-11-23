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

# Run Grafana Agent
exec /usr/bin/grafana-agent-flow run \
  --storage.path=/tmp/agent \
  --server.http.listen-addr=0.0.0.0:12345 \
  /etc/grafana-agent/agent.river
