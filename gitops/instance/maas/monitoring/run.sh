#!/bin/sh
APP_NAME=maas-monitoring

# Default (all off — safe dry-run):
# helm template . --name-template ${APP_NAME}

# Enable Grafana dashboards only (Grafana Operator already installed):
# helm template . --name-template ${APP_NAME} \
#   --set grafana.enabled=true \
#   --set grafana.namespace=llama-stack-demo-user1

# Enable everything (requires Kuadrant + vLLM deployed):
# helm template . --name-template ${APP_NAME} \
#   --set grafana.enabled=true \
#   --set grafana.namespace=llama-stack-demo-user1 \
#   --set limitador.enabled=true \
#   --set alerting.limitador.enabled=true \
#   --set alerting.gateway.enabled=true \
#   --set vllm.enabled=true \
#   --set vllm.modelNamespace=models-as-a-service

helm template . --name-template ${APP_NAME}
