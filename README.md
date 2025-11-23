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

## GitHub Actions Configuration

The build workflow fetches the Grafana service account token from Terraform Cloud. You need to configure the following secrets in your GitHub repository:

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
