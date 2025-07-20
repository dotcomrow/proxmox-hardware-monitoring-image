#!/bin/bash
set -e

# Inject secrets into River config
sed -i "s/GRAFANA_USERNAME_PLACEHOLDER/${GRAFANA_USERNAME}/g" /etc/grafana-agent/agent.river
sed -i "s/GRAFANA_API_KEY_PLACEHOLDER/${GRAFANA_API_KEY}/g" /etc/grafana-agent/agent.river

/opt/dell/srvadmin/sbin/dsm_sa_datamgrd &
/opt/dell/srvadmin/sbin/dsm_sa_eventmgrd &
/opt/dell/srvadmin/sbin/dsm_sa_snmpd &


# Start collector in background loop
echo "Starting metrics collector loop..."
(
  while true; do
    /opt/dell-exporter/collect.sh
    sleep 60
  done
) &

# Run Grafana Agent
exec /usr/bin/grafana-agent-flow run \
  --storage.path=/tmp/agent \
  --server.http.listen-addr=0.0.0.0:12345 \
  /etc/grafana-agent/agent.river
