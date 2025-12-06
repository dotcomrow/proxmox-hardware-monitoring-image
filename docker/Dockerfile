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
RUN mkdir -p /opt/dell-exporter /etc/grafana-agent

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

# Install Grafana Agent (Flow-capable) from upstream release (includes otelcol components)
ARG AGENT_VERSION=0.53.2
RUN set -eux; \
    curl -fsSL -o /tmp/agent.zip "https://github.com/grafana/agent/releases/download/v${AGENT_VERSION}/grafana-agent-${AGENT_VERSION}-linux-amd64.zip"; \
    unzip /tmp/agent.zip -d /tmp/agent; \
    install -m755 "/tmp/agent/grafana-agent-${AGENT_VERSION}-linux-amd64" /usr/bin/grafana-agent; \
    ln -sf /usr/bin/grafana-agent /usr/bin/grafana-agent-flow; \
    /usr/bin/grafana-agent --version; \
    rm -rf /tmp/agent /tmp/agent.zip

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
    dnf -y install smartmontools ipmitool; \
    dnf clean all

# Create dummy River config for build-time validation
RUN echo 'server "default" { log_level = "info" } loki.write "default" { endpoint { url = "http://localhost:3100/loki/api/v1/push" } } loki.source.file "dummy" { targets = [] forward_to = [loki.write.default.receiver] }' > /etc/grafana-agent/dummy.river && \
    /usr/bin/grafana-agent run --config.file=/etc/grafana-agent/dummy.river --help || true

# Add real collector and config
COPY collect.sh /opt/dell-exporter/collect.sh
COPY agent.yaml /etc/grafana-agent/agent.river
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /opt/dell-exporter/collect.sh /entrypoint.sh

EXPOSE 12345/tcp 5514/tcp 5514/udp 4317/tcp 4318/tcp

ENTRYPOINT ["/entrypoint.sh"]
