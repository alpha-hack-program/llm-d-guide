#!/bin/sh
APP_NAME=mcp-gateway
CLUSTER_DOMAIN=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')
OIDC_HOST=${OIDC_HOST:=keycloak.${CLUSTER_DOMAIN}}

echo "CLUSTER_DOMAIN=${CLUSTER_DOMAIN}"

# The default tenant's fields are plain scalars, so --set is safe here —
# unlike extraTenants[], which must always be set via -f (see values.yaml
# and "Adding a tenant" in docs/phases/08-mcp-gateway.md).
helm template . --name-template ${APP_NAME} \
  --set gateway.publicHost="mcp.${CLUSTER_DOMAIN}" \
  --set oidc.issuer="https://${OIDC_HOST}/realms/default" \
  --include-crds
