# Dell Hardware Exporter

Docker image to monitor proxmox host hardware
Exports Dell server chassis metrics using OMSA and Grafana Agent.

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
