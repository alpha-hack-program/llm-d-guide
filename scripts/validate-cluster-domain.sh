#!/bin/bash
# Validates that the cluster domain is extracted correctly
# Works for ANY OpenShift cluster by comparing against cluster configuration
# Usage: ./scripts/validate-cluster-domain.sh

set -e

echo "Validating cluster domain extraction..."
echo ""

# Extract the cluster domain and apps domain
CLUSTER_DOMAIN=$(oc get dns.config/cluster -o jsonpath='{.spec.baseDomain}')
APPS_DOMAIN=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')

if [[ -z "${CLUSTER_DOMAIN}" ]]; then
  echo "❌ ERROR: Could not extract cluster domain from dns.config/cluster"
  echo "   Make sure you are logged into the OpenShift cluster"
  exit 1
fi

if [[ -z "${APPS_DOMAIN}" ]]; then
  echo "❌ ERROR: Could not extract apps domain from ingresses.config/cluster"
  exit 1
fi

echo "✅ Cluster domain extracted: ${CLUSTER_DOMAIN}"
echo ""

# CRITICAL VALIDATION: Apps domain must be apps.<baseDomain>
# This catches the mistake of using the parent domain instead of the full cluster domain
EXPECTED_APPS="apps.${CLUSTER_DOMAIN}"

if [[ "${APPS_DOMAIN}" != "${EXPECTED_APPS}" ]]; then
  echo "❌ ERROR: The extracted cluster domain does not match the cluster's actual configuration!"
  echo ""
  echo "   What you extracted:        ${CLUSTER_DOMAIN}"
  echo "   Cluster's actual apps:     ${APPS_DOMAIN}"
  echo "   Would expect apps to be:   ${EXPECTED_APPS}"
  echo ""
  echo "   MISMATCH! The cluster domain you extracted is incorrect."
  echo ""
  echo "   This usually means you extracted a parent domain instead of the full cluster base domain."
  echo ""
  echo "   To fix:"
  echo "   1. Check what the cluster actually has:"
  echo "      oc get dns.config/cluster -o jsonpath='{.spec.baseDomain}'"
  echo ""
  echo "   2. Use that EXACT value as clusterDomain"
  echo ""
  exit 1
fi

echo "✅ Apps domain matches expected pattern: ${APPS_DOMAIN}"
echo ""

# Extract AWS region if on AWS
PLATFORM=$(oc get infrastructure cluster -o jsonpath='{.status.platform}' 2>/dev/null || echo "unknown")
AWS_REGION="N/A"
if [[ "${PLATFORM}" == "AWS" ]]; then
  AWS_REGION=$(oc get infrastructure cluster -o jsonpath='{.status.platformStatus.aws.region}' 2>/dev/null || echo "unknown")
fi

echo "Cluster configuration:"
echo "  Platform:     ${PLATFORM}"
echo "  Base domain:  ${CLUSTER_DOMAIN}"
echo "  Apps domain:  ${APPS_DOMAIN}"
echo "  AWS region:   ${AWS_REGION}"
echo ""

# Validate format - should have at least 2 dots for most OpenShift IPI clusters
DOT_COUNT=$(echo "${CLUSTER_DOMAIN}" | tr -cd '.' | wc -c | xargs)

if [[ ${DOT_COUNT} -lt 1 ]]; then
  echo "⚠️  WARNING: Cluster domain has unusual format (expected at least 1 dot)"
  echo "   Got: ${CLUSTER_DOMAIN}"
  echo "   This may be valid for some cluster types, but verify it is correct."
  echo ""
fi

echo "✅ Cluster domain validation passed"
echo ""
echo "Use these values for cert-manager-route53:"
echo "  --set clusterDomain=\"${CLUSTER_DOMAIN}\""
if [[ "${PLATFORM}" == "AWS" ]]; then
  echo "  --set route53.region=\"${AWS_REGION}\""
fi
