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

# Install Grafana Agent Flow from official repo
RUN wget -q -O /etc/pki/rpm-grafana.key https://rpm.grafana.com/gpg.key && \
    rpm --import /etc/pki/rpm-grafana.key && \
    echo -e '[grafana]\nname=grafana\nbaseurl=https://rpm.grafana.com\nrepo_gpgcheck=1\nenabled=1\ngpgcheck=1\ngpgkey=https://rpm.grafana.com/gpg.key\nsslverify=1\nsslcacert=/etc/pki/tls/certs/ca-bundle.crt' > /etc/yum.repos.d/grafana.repo && \
    dnf -y update && \
    dnf -y install grafana-agent-flow

# Install Fluent Bit (optional syslog -> GCP Cloud Logging forwarding)
RUN set -eux; \
    curl -fsSL https://packages.fluentbit.io/fluentbit.key -o /etc/pki/rpm-gpg/RPM-GPG-KEY-FluentBit; \
    printf '%s\n' \
      '[fluent-bit]' \
      'name=Fluent Bit' \
      'baseurl=https://packages.fluentbit.io/centos/8' \
      'enabled=1' \
      'gpgcheck=1' \
      'gpgkey=https://packages.fluentbit.io/fluentbit.key' \
      > /etc/yum.repos.d/fluent-bit.repo; \
    dnf -y install fluent-bit

# Create dummy River config for build-time validation
RUN echo 'server "default" { log_level = "info" } loki.write "default" { endpoint { url = "http://localhost:3100/loki/api/v1/push" } } loki.source.file "dummy" { targets = [] forward_to = [loki.write.default.receiver] }' > /etc/grafana-agent/dummy.river && \
    /usr/bin/grafana-agent run --config.file=/etc/grafana-agent/dummy.river --help || true

# Add real collector and config
COPY collect.sh /opt/dell-exporter/collect.sh
COPY agent.yaml /etc/grafana-agent/agent.river
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /opt/dell-exporter/collect.sh /entrypoint.sh

EXPOSE 12345/tcp 5514/tcp 5514/udp

ENTRYPOINT ["/entrypoint.sh"]
