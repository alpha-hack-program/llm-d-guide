#!/bin/sh
APP_NAME=cert-manager-operator
# VALUES="--values intel.yaml"
# VALUES="--values nvidia.yaml"
# VALUES=""

helm template . -f ./values.yaml --name-template ${APP_NAME} \
  --include-crds ${VALUES} 
  