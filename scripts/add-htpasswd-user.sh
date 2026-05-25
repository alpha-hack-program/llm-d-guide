#!/usr/bin/env bash
# add-htpasswd-user.sh — generate an htpasswd entry and print the manual steps
# to add it to the OpenShift htpasswd identity provider secret.
#
# Usage:
#   ./scripts/add-htpasswd-user.sh <username> [password]
#
# If password is omitted, the script prompts for it (no echo).
#
# Prerequisites:
#   - oc (logged in as cluster-admin)
#   - htpasswd (from httpd-tools / apache2-utils) OR openssl (fallback)

set -euo pipefail

# --------------------------------------------------------------------------- #
# Args / password prompt
# --------------------------------------------------------------------------- #
USERNAME="${1:-}"
PASSWORD="${2:-}"

if [[ -z "${USERNAME}" ]]; then
  echo "Usage: $0 <username> [password]" >&2
  exit 1
fi

if [[ -z "${PASSWORD}" ]]; then
  read -rsp "Password for '${USERNAME}': " PASSWORD
  echo
  read -rsp "Confirm password: " PASSWORD2
  echo
  if [[ "${PASSWORD}" != "${PASSWORD2}" ]]; then
    echo "Error: passwords do not match." >&2
    exit 1
  fi
fi

# --------------------------------------------------------------------------- #
# Cluster login check
# --------------------------------------------------------------------------- #
if ! oc whoami &>/dev/null; then
  echo "Error: not logged in to OpenShift. Run 'oc login ...' first." >&2
  exit 1
fi

# --------------------------------------------------------------------------- #
# Discover the htpasswd secret from the OAuth cluster config
# --------------------------------------------------------------------------- #
SECRET_NAMES=$(oc get oauth cluster \
  -o jsonpath='{.spec.identityProviders[?(@.type=="HTPasswd")].htpasswd.fileData.name}' \
  2>/dev/null || true)

if [[ -z "${SECRET_NAMES}" ]]; then
  echo "Error: no HTPasswd identity provider found in 'oc get oauth cluster'." >&2
  echo "       Create one first:" >&2
  echo ""
  echo "  oc create secret generic htpasswd-secret -n openshift-config --from-literal=htpasswd=''"
  echo "  oc patch oauth cluster --type=json -p '[{"
  echo "    \"op\":\"add\",\"path\":\"/spec/identityProviders/-\","
  echo "    \"value\":{\"name\":\"htpasswd\",\"type\":\"HTPasswd\","
  echo "             \"htpasswd\":{\"fileData\":{\"name\":\"htpasswd-secret\"}}}}]'"
  exit 1
fi

SECRET_NAME="${SECRET_NAMES%% *}"
SECRET_NS="openshift-config"

# --------------------------------------------------------------------------- #
# Generate the htpasswd entry
# --------------------------------------------------------------------------- #
if command -v htpasswd &>/dev/null; then
  HTPASSWD_LINE=$(htpasswd -Bnb "${USERNAME}" "${PASSWORD}")
elif command -v python3 &>/dev/null && python3 -c "import bcrypt" &>/dev/null 2>&1; then
  HASHED=$(python3 -c "import bcrypt, sys; \
    print(bcrypt.hashpw(sys.argv[1].encode(), bcrypt.gensalt(rounds=12)).decode())" \
    "${PASSWORD}")
  HTPASSWD_LINE="${USERNAME}:${HASHED}"
else
  echo "Error: 'htpasswd' not found and 'python3 bcrypt' not available." >&2
  echo "       Install httpd-tools (RHEL/Fedora) or apache2-utils (Debian/Ubuntu)." >&2
  exit 1
fi

# --------------------------------------------------------------------------- #
# Output — just the htpasswd line, suitable for scripting
# --------------------------------------------------------------------------- #
echo "${HTPASSWD_LINE}"
