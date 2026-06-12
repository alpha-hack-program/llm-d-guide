# Utility Scripts

Testing and development utilities for llm-d monitoring.

## Files

- `generate-metrics.sh` — Send test traffic to populate dashboard metrics
- `test-cache-hits.sh` — Verify prefix caching is working
- `install.sh` — Automated COO + dashboard installation (legacy)

## Usage

These scripts are **not required** for production deployments. They are provided for:
- Testing dashboard configurations
- Verifying monitoring setup
- Development/troubleshooting

## Production Deployment

For production, use the deployment commands in:
- [README.md Step 6](../../../../README.md#step-6-deploy-monitoring)
- [AGENTS.md Phase 4](../../../../AGENTS.md#phase-4--monitoring-stack)
