# Dell Hardware Exporter

Docker image to monitor proxmox host hardware
Exports Dell server chassis metrics using OMSA and Grafana Agent.

## Usage

Build and run the image on `linux/amd64` (OMSA only ships x86_64 binaries):

```bash
cd docker
docker build --platform=linux/amd64 -t dell-hardware-exporter .

docker run -d \
  --name dell-hw-exporter \
  -e GRAFANA_API_KEY=your_grafana_cloud_token \
  -e GRAFANA_USERNAME=2361797 \
  -p 12345:12345 \
  dell-hardware-exporter
```

`GRAFANA_USERNAME` is optional (defaults to the stack id above); `GRAFANA_API_KEY` is required.

The container will refuse to start if the Grafana API key placeholder is still present to avoid spamming 401s.

### Optional: receive iDRAC syslog and forward to GCP Cloud Logging

The image now ships with Fluent Bit to accept syslog from iDRAC (or anything else) and push it to GCP:

- Exposes 5514/udp and 5514/tcp (defaults to UDP).
- Enable by setting `ENABLE_SYSLOG_FORWARDING=true`.
- Required env: `GCP_PROJECT_ID`, `GOOGLE_APPLICATION_CREDENTIALS` (path to mounted service account JSON).
- Optional env: `SYSLOG_PORT` (default `5514`), `SYSLOG_MODE` (`udp` or `tcp`, default `udp`), `GCP_LOG_NAME` (default `idrac-syslog`), `GCP_RESOURCE` (default `global`).

Example run:

```bash
docker run -d \
  --name dell-hw-exporter \
  -e GRAFANA_API_KEY=your_grafana_cloud_token \
  -e ENABLE_SYSLOG_FORWARDING=true \
  -e GCP_PROJECT_ID=my-gcp-project \
  -e GOOGLE_APPLICATION_CREDENTIALS=/var/secrets/gcp-sa.json \
  -v /path/to/gcp-sa.json:/var/secrets/gcp-sa.json:ro \
  -p 12345:12345 \
  -p 5514:5514/udp \
  dell-hardware-exporter
```

Then point iDRAC remote syslog to `udp://<host-ip>:5514` (or TCP if you set `SYSLOG_MODE=tcp`). Logs will show up in Cloud Logging under `logName=projects/<project>/logs/idrac-syslog`.

## GitHub Actions Configuration

The build workflow fetches the Grafana service account token from Terraform Cloud **unless** it is supplied directly via GitHub secrets.

- Preferred: set a GitHub secret `GRAFANA_SERVICE_ACCOUNT_TOKEN` with the Grafana API key.
- If you rely on Terraform Cloud variable sets, the token **must not be marked sensitive** (Terraform Cloud will not return sensitive values over the API). The workflow will fail fast and tell you to use the GitHub secret if the variable is sensitive.

You need to configure the following secrets in your GitHub repository:

### Required GitHub Secrets

1. **TF_API_TOKEN**: Your Terraform Cloud API token
   - Go to Terraform Cloud → User Settings → Tokens
   - Create a new API token and add it to GitHub repository secrets

2. **TF_ORGANIZATION**: Your Terraform Cloud organization name
   - This is the organization that contains your workspace

3. **TF_WORKSPACE**: The Terraform workspace name that contains the "K8S Cluster Variables" variable set
   - This workspace should have access to the `grafana_service_account_token` variable

### Terraform Cloud Setup

Ensure your Terraform Cloud workspace has a variable set called "K8S Cluster Variables" containing:

- `grafana_service_account_token`: The Grafana service account token (marked as sensitive)

The workflow will automatically fetch this token and replace the hardcoded value in `docker/agent.yaml` during the build process.
