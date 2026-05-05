#!/usr/bin/env bash
set -euo pipefail

PACKAGE=nfd
SOURCE=redhat-operators

CHANNEL=$(oc get packagemanifest "${PACKAGE}" -n openshift-marketplace \
  -o jsonpath='{.status.defaultChannel}')
CSV=$(oc get packagemanifest "${PACKAGE}" -n openshift-marketplace \
  -o jsonpath="{.status.channels[?(@.name==\"${CHANNEL}\")].currentCSV}")

echo "Installing NFD operator: channel=${CHANNEL} csv=${CSV}"

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

oc apply -f "${DIR}/operator.yaml"

oc patch subscription nfd -n openshift-nfd --type merge -p \
  "{\"spec\":{\"channel\":\"${CHANNEL}\",\"startingCSV\":\"${CSV}\"}}"
