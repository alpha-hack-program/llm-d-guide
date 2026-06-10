#!/bin/sh
APP_NAME=gateway

helm template ${APP_NAME} . \
  --set clusterDomain="${CLUSTER_DOMAIN}" \
  --include-crds
