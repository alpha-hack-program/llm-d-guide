#!/bin/sh
APP_NAME=maas-gateway
GATEWAY_NAME=${GATEWAY_NAME:=maas-default-gateway}
CLUSTER_DOMAIN=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')

echo "CLUSTER_DOMAIN=${CLUSTER_DOMAIN}"

# --- OpenShift Route + existing wildcard cert (default / AWS) ---
# helm template . --name-template ${APP_NAME} \
#   --set gateway.name="${GATEWAY_NAME}" \
#   --set clusterDomain="${CLUSTER_DOMAIN}" \
#   --set useOpenShiftRoute=true \
#   --set tls.secretName=ingress-certs \
#   --set limitador.exhaustiveTelemetry=false \
#   --set telemetry.enabled=false \
#   --include-crds

# --- OpenShift Route + self-signed cert (cert-manager) ---
# helm template . --name-template ${APP_NAME} \
#   --set gateway.name="${GATEWAY_NAME}" \
#   --set clusterDomain="${CLUSTER_DOMAIN}" \
#   --set useOpenShiftRoute=true \
#   --set tls.secretName="${GATEWAY_NAME}-tls" \
#   --set tls.generate=true \
#   --include-crds

# --- OpenShift Route + Let's Encrypt cert (cert-manager) ---
# helm template . --name-template ${APP_NAME} \
#   --set gateway.name="${GATEWAY_NAME}" \
#   --set clusterDomain="${CLUSTER_DOMAIN}" \
#   --set useOpenShiftRoute=true \
#   --set tls.secretName="${GATEWAY_NAME}-tls" \
#   --set tls.generate=true \
#   --set tls.issuerName=letsencrypt \
#   --include-crds

# --- LoadBalancer + existing cert ---
# helm template . --name-template ${APP_NAME} \
#   --set gateway.name="${GATEWAY_NAME}" \
#   --set clusterDomain="${CLUSTER_DOMAIN}" \
#   --set subdomain=maas \
#   --set useOpenShiftRoute=false \
#   --set gateway.serviceType=LoadBalancer \
#   --set tls.secretName=ingress-certs \
#   --include-crds

helm template . --name-template ${APP_NAME} \
  --set gateway.name="${GATEWAY_NAME}" \
  --set clusterDomain="${CLUSTER_DOMAIN}" \
  --set useOpenShiftRoute=true \
  --set tls.secretName=ingress-certs \
  --set limitador.exhaustiveTelemetry=false \
  --set telemetry.enabled=false \
  --include-crds
