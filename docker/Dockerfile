FROM --platform=linux/amd64 rockylinux:8

# OMSA binaries are only published for x86_64. Fail fast if someone tries to
# build on another architecture (for example, Apple Silicon without --platform).
RUN set -eux; \
    arch="$(uname -m)"; \
    if [ "$arch" != "x86_64" ]; then \
      echo "Dell OMSA only ships x86_64 binaries, got ${arch}"; \
      exit 1; \
    fi

# Install required tools
RUN dnf -y install \
    wget \
    tar \
    unzip \
    systemd \
    findutils \
    procps \
    which \
    glibc-langpack-en \
    gnupg \
    && dnf clean all

# Create working and export directories
WORKDIR /opt/omsa
RUN mkdir -p /opt/dell-exporter /etc/grafana-agent /etc/otelcol

# Download OMSA 10.1 and install the RHEL8 x86_64 RPMs
RUN set -eux; \
    wget --header="User-Agent: Mozilla/5.0" -O omsa.tar.gz \
      https://dl.dell.com/FOLDER07414935M/1/OM-SrvAdmin-Dell-Web-LX-10.1.0.0-4561_A00.tar.gz; \
    tar -xzf omsa.tar.gz; \
    dnf -y install $(find ./linux -type f -path "*/RHEL8/x86_64/*.rpm"); \
    test -x /opt/dell/srvadmin/bin/omreport; \
    rm -rf omsa.tar.gz linux

# Set environment for OMSA tools
ENV PATH="/opt/dell/srvadmin/bin:/opt/dell/srvadmin/sbin:${PATH}"
ENV LD_LIBRARY_PATH=/opt/dell/srvadmin/lib64
RUN echo "/opt/dell/srvadmin/lib64" > /etc/ld.so.conf.d/srvadmin.conf && ldconfig

# Install Grafana Agent Flow from official repo (textfile scrape) and OpenTelemetry Collector Contrib for OTLP bridge
RUN set -eux; \
    wget -q -O /etc/pki/rpm-grafana.key https://rpm.grafana.com/gpg.key; \
    rpm --import /etc/pki/rpm-grafana.key; \
    printf '%s\n' \
      '[grafana]' \
      'name=grafana' \
      'baseurl=https://rpm.grafana.com' \
      'repo_gpgcheck=0' \
      'enabled=1' \
      'gpgcheck=1' \
      'gpgkey=https://rpm.grafana.com/gpg.key' \
      'sslverify=1' \
      'sslcacert=/etc/pki/tls/certs/ca-bundle.crt' \
      > /etc/yum.repos.d/grafana.repo; \
    dnf -y update && dnf -y install grafana-agent-flow; \
    OTEL_VERSION="0.98.0"; \
    curl -fsSL -o /tmp/otelcol.tar.gz "https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v${OTEL_VERSION}/otelcol-contrib_${OTEL_VERSION}_linux_amd64.tar.gz"; \
    tar -xzf /tmp/otelcol.tar.gz -C /tmp; \
    install -m755 /tmp/otelcol-contrib /usr/bin/otelcol-contrib; \
    ln -sf /usr/bin/grafana-agent-flow /usr/bin/grafana-agent; \
    /usr/bin/grafana-agent-flow --version; \
    /usr/bin/otelcol-contrib --version; \
    rm -rf /tmp/otelcol.tar.gz /tmp/otelcol* /var/cache/dnf

# Install ipmi_exporter for IPMI metrics (Prometheus standard)
ARG IPMI_EXPORTER_VERSION=1.7.0
RUN set -eux; \
    curl -fsSL -o /tmp/ipmi_exporter.tar.gz "https://github.com/prometheus-community/ipmi_exporter/releases/download/v${IPMI_EXPORTER_VERSION}/ipmi_exporter-${IPMI_EXPORTER_VERSION}.linux-amd64.tar.gz"; \
    tar -xzf /tmp/ipmi_exporter.tar.gz -C /tmp; \
    install -m755 "/tmp/ipmi_exporter-${IPMI_EXPORTER_VERSION}.linux-amd64/ipmi_exporter" /usr/local/bin/ipmi_exporter; \
    rm -rf /tmp/ipmi_exporter* /var/cache/dnf

# Install Fluent Bit (optional syslog -> GCP Cloud Logging forwarding)
RUN set -eux; \
    curl -fsSL https://packages.fluentbit.io/fluentbit.key -o /etc/pki/rpm-gpg/RPM-GPG-KEY-FluentBit; \
    printf '%s\n' \
      '[fluent-bit]' \
      'name=Fluent Bit' \
      'baseurl=https://packages.fluentbit.io/rockylinux/$releasever/' \
      'enabled=1' \
      'gpgcheck=1' \
      'repo_gpgcheck=1' \
      'gpgkey=https://packages.fluentbit.io/fluentbit.key' \
      > /etc/yum.repos.d/fluent-bit.repo; \
    dnf -y install fluent-bit; \
    mkdir -p /fluent-bit/bin; \
    ln -sf /opt/fluent-bit/bin/fluent-bit /fluent-bit/bin/fluent-bit; \
    ln -sf /opt/fluent-bit/bin/fluent-bit /usr/local/bin/fluent-bit; \
    /opt/fluent-bit/bin/fluent-bit --version
ENV PATH="/opt/fluent-bit/bin:${PATH}"

# SMART monitoring tools (best-effort SMART metrics)
RUN set -eux; \
    # ipmitool is handy for manual inspection; freeipmi provides the binaries ipmi_exporter uses
    dnf -y install smartmontools ipmitool freeipmi; \
    dnf clean all

# Create dummy River config for build-time validation
RUN echo 'server "default" { log_level = "info" } loki.write "default" { endpoint { url = "http://localhost:3100/loki/api/v1/push" } } loki.source.file "dummy" { targets = [] forward_to = [loki.write.default.receiver] }' > /etc/grafana-agent/dummy.river && \
    /usr/bin/grafana-agent run --config.file=/etc/grafana-agent/dummy.river --help || true

# Add real collector and config
COPY collect.sh /opt/dell-exporter/collect.sh
COPY collect_lib.sh /opt/dell-exporter/collect_lib.sh
COPY collect_lib_lst.sh /opt/dell-exporter/collect_lib_lst.sh
COPY collect_lib_xml.sh /opt/dell-exporter/collect_lib_xml.sh
COPY agent.yaml /etc/grafana-agent/agent.river
COPY otelcol.yaml /etc/otelcol/config.yaml
COPY ipmi_exporter.yml /etc/ipmi_exporter.yml
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /opt/dell-exporter/collect.sh /opt/dell-exporter/collect_lib.sh /opt/dell-exporter/collect_lib_lst.sh /opt/dell-exporter/collect_lib_xml.sh /entrypoint.sh

EXPOSE 12345/tcp 5514/tcp 5514/udp 4317/tcp 4318/tcp

ENTRYPOINT ["/entrypoint.sh"]
