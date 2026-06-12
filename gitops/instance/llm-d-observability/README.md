# llm-d Observability

Perses dashboards and monitoring configuration for llm-d inference deployments.

---

## Files in This Directory

### Active Deployment Artifacts

**LLMInferenceService (intelligent-inference):**
- `perses-dashboard-intelligent-inference.yaml` — Perses dashboard for intelligent-inference models
- `LLM-D-MONITORING-INTEGRATION.md` — Complete technical reference (architecture, metrics, troubleshooting)

**ExternalModel:**
- `perses-dashboard-external-models.yaml` — Perses dashboard for ExternalModel (Limitador metrics)
- `limitador-servicemonitor.yaml` — ServiceMonitor for Limitador rate limiting metrics
- `EXTERNAL-MONITORING-INTEGRATION.md` — Complete technical reference (ExternalModel monitoring)

### Subdirectories

- `scripts/` — Utility scripts (testing, metric generation)
- `legacy-dashboards/` — Old/draft dashboard versions (not used in README.md/AGENTS.md)
- `archive/` — Deprecated files (old README, manual ServiceMonitor, kustomization)
- `docs.bkp/` — Old documentation files (pre-consolidation backup)

---

## Deployment

### LLMInferenceService Monitoring

**Prerequisites:**
- User Workload Monitoring enabled
- Cluster Observability Operator installed

**Deploy dashboard:**
```bash
oc apply -f perses-dashboard-intelligent-inference.yaml
```

**Note:** ServiceMonitors are created automatically by the inference chart when you deploy a model.

**Technical details:**  
See [LLM-D-MONITORING-INTEGRATION.md](LLM-D-MONITORING-INTEGRATION.md)

---

### ExternalModel Monitoring

**Prerequisites:**
- User Workload Monitoring enabled
- Cluster Observability Operator installed
- Kuadrant namespace labeled for cluster monitoring

**Deploy ServiceMonitor + dashboard:**
```bash
oc label namespace kuadrant-system openshift.io/cluster-monitoring=true --overwrite
oc apply -f limitador-servicemonitor.yaml
oc apply -f perses-dashboard-external-models.yaml
```

**Technical details:**  
See [EXTERNAL-MONITORING-INTEGRATION.md](EXTERNAL-MONITORING-INTEGRATION.md)

---

## Access Dashboards

OpenShift Console → **Observe** → **Dashboards** (Perses tab)

**Available dashboards:**
- **llm-d Intelligent Inference** — Prefix caching, TTFT, EPP scheduler (LLMInferenceService)
- **MaaS External Models** — Rate limiting, token consumption (ExternalModel)

---

## Quick Reference

| Model Type | Dashboard | ServiceMonitor | Metrics Source |
|-----------|-----------|----------------|----------------|
| LLMInferenceService | `perses-dashboard-intelligent-inference.yaml` | Auto-created by chart | vLLM + EPP |
| ExternalModel | `perses-dashboard-external-models.yaml` | `limitador-servicemonitor.yaml` | Limitador |

---

## Related Documentation

- [README.md Step 6](../../../README.md#step-6-deploy-monitoring) — Deployment commands
- [AGENTS.md Phase 4](../../../AGENTS.md#phase-4--monitoring-stack) — Deployment commands
- [Cluster Observability Operator](https://docs.openshift.com/container-platform/4.21/observability/cluster_observability_operator/index.html)
- [vLLM Metrics](https://docs.vllm.ai/en/latest/serving/metrics.html)
