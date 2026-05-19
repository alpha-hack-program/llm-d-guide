#!/bin/sh
APP_NAME=maas-database
NAMESPACE=${NAMESPACE:-redhat-ods-applications}

# Dry-run (password will be random since lookup is skipped in template mode):
helm template . --name-template ${APP_NAME} --namespace ${NAMESPACE}

# Install with auto-generated password:
# helm install ${APP_NAME} . --namespace ${NAMESPACE}

# Install with explicit password (required for ArgoCD):
# helm install ${APP_NAME} . --namespace ${NAMESPACE} --set db.password=<your-password>

# Upgrade (reuses existing password via lookup):
# helm upgrade ${APP_NAME} . --namespace ${NAMESPACE}
