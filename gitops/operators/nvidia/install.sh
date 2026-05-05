#!/usr/bin/env bash
set -euo pipefail

PACKAGE=gpu-operator-certified
SOURCE=certified-operators

CHANNEL=$(oc get packagemanifest "${PACKAGE}" -n openshift-marketplace \
  -o jsonpath='{.status.defaultChannel}')
CSV=$(oc get packagemanifest "${PACKAGE}" -n openshift-marketplace \
  -o jsonpath="{.status.channels[?(@.name==\"${CHANNEL}\")].currentCSV}")

echo "Installing NVIDIA GPU Operator: channel=${CHANNEL} csv=${CSV}"

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

sed "s/NVIDIA_CHANNEL_PLACEHOLDER/${CHANNEL}/" "${DIR}/operator.yaml" | oc apply -f -

oc patch subscription gpu-operator-certified -n nvidia-gpu-operator --type merge -p \
  "{\"spec\":{\"startingCSV\":\"${CSV}\"}}"
