FROM rockylinux:8

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

# Download OMSA 10.1
RUN wget --header="User-Agent: Mozilla/5.0" \
    https://dl.dell.com/FOLDER07414935M/1/OM-SrvAdmin-Dell-Web-LX-10.1.0.0-4561_A00.tar.gz && \
    tar -xvzf OM-SrvAdmin-Dell-Web-LX-10.1.0.0-4561_A00.tar.gz

# Install only RHEL8 RPMs one-by-one to avoid dependency hell
RUN find ./linux -type f -name "*.rpm" | grep RHEL8 | while read rpm; do \
    echo "Installing $rpm" && \
    dnf -y install "$rpm" --skip-broken || echo "Failed to install $rpm"; \
  done

# Set environment for OMSA tools
ENV PATH="/opt/dell/srvadmin/bin:/opt/dell/srvadmin/sbin:${PATH}"
ENV LD_LIBRARY_PATH=/opt/dell/srvadmin/lib64:$LD_LIBRARY_PATH
RUN echo "/opt/dell/srvadmin/lib64" > /etc/ld.so.conf.d/srvadmin.conf && ldconfig

# Install Grafana Agent Flow from official repo
RUN wget -q -O /etc/pki/rpm-grafana.key https://rpm.grafana.com/gpg.key && \
    rpm --import /etc/pki/rpm-grafana.key && \
    echo -e '[grafana]\nname=grafana\nbaseurl=https://rpm.grafana.com\nrepo_gpgcheck=1\nenabled=1\ngpgcheck=1\ngpgkey=https://rpm.grafana.com/gpg.key\nsslverify=1\nsslcacert=/etc/pki/tls/certs/ca-bundle.crt' > /etc/yum.repos.d/grafana.repo && \
    dnf -y update && \
    dnf -y install grafana-agent-flow

# Create dummy River config for build-time validation
RUN echo 'server "default" { log_level = "info" } loki.write "default" { endpoint { url = "http://localhost:3100/loki/api/v1/push" } } loki.source.file "dummy" { targets = [] forward_to = [loki.write.default.receiver] }' > /etc/grafana-agent/dummy.river && \
    /usr/bin/grafana-agent run --config.file=/etc/grafana-agent/dummy.river --help || true

# Add real collector and config
COPY collect.sh /opt/dell-exporter/collect.sh
COPY agent.yaml /etc/grafana-agent/agent.river
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /opt/dell-exporter/collect.sh /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]