#!/bin/sh
APP_NAME=gateway

helm template . --name-template ${APP_NAME} \
  --set clusterDomain="${CLUSTER_DOMAIN}" \
  --include-crds
