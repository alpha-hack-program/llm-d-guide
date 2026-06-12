#!/bin/bash
# Extract AWS credentials from OpenShift cert-manager secret and configure AWS CLI
# These credentials are temporary and scoped to cert-manager Route53 operations only

set -e

echo "Extracting AWS credentials from OpenShift secret..."

# Extract credentials from the OpenShift secret
AWS_ACCESS_KEY_ID=$(oc get secret aws-creds -n cert-manager -o jsonpath='{.data.aws_access_key_id}' | base64 -d)
AWS_SECRET_ACCESS_KEY=$(oc get secret aws-creds -n cert-manager -o jsonpath='{.data.aws_secret_access_key}' | base64 -d)

# Export as environment variables (only for this shell session)
export AWS_ACCESS_KEY_ID
export AWS_SECRET_ACCESS_KEY
export AWS_DEFAULT_REGION="eu-west-1"

echo "✅ AWS credentials configured for this shell session"
echo "   Region: ${AWS_DEFAULT_REGION}"
echo ""
echo "You can now run AWS CLI commands, for example:"
echo "  aws route53 list-hosted-zones"
echo "  aws route53 list-resource-record-sets --hosted-zone-id Z2JW8VN70KFH7P"
echo ""
echo "To apply these settings, run:"
echo "  source .aws-creds-setup.sh"
