#!/usr/bin/env bash
# Approve only RHCL / Kuadrant-stack InstallPlans that stay on the pinned 1.3.x line.
# Never use a blanket "approve all pending InstallPlans" loop for openshift-operators.
#
# Usage:
#   ./scripts/approve-rhcl-installplan.sh              # list pending plans (default)
#   ./scripts/approve-rhcl-installplan.sh --approve   # approve safe plans only
#
# See docs/reference/rhcl-version-pin.md

set -euo pipefail

NAMESPACE="${RHCL_INSTALLPLAN_NAMESPACE:-openshift-operators}"
APPROVE=false
MAX_RHCL_MINOR=3
MIN_RHCL_PATCH=5

usage() {
  sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --approve) APPROVE=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 2 ;;
  esac
done

csv_minor() {
  # rhcl-operator.v1.4.2 -> 4
  local name="$1"
  if [[ "$name" =~ \.v([0-9]+)\. ]]; then
    echo "${BASH_REMATCH[1]}"
  else
    echo "999"
  fi
}

csv_patch() {
  # rhcl-operator.v1.3.6 -> 6
  local name="$1"
  if [[ "$name" =~ \.v[0-9]+\.([0-9]+) ]]; then
    echo "${BASH_REMATCH[1]}"
  else
    echo "0"
  fi
}

is_kuadrant_stack_csv() {
  case "$1" in
    rhcl-operator.*|authorino-operator.*|limitador-operator.*|dns-operator.*) return 0 ;;
    *) return 1 ;;
  esac
}

plan_verdict() {
  local -a csvs=("$@")
  local has_rhcl=false rhcl_minor="" blocked=false reason=""

  for csv in "${csvs[@]}"; do
    if [[ "$csv" == rhcl-operator.* ]]; then
      has_rhcl=true
      rhcl_minor=$(csv_minor "$csv")
      if (( rhcl_minor > MAX_RHCL_MINOR )); then
        blocked=true
        reason="targets ${csv} (repo pin is rhcl-operator v1.3.x)"
      elif (( rhcl_minor == MAX_RHCL_MINOR )); then
        local patch
        patch=$(csv_patch "$csv")
        if (( patch < MIN_RHCL_PATCH )); then
          blocked=true
          reason="targets ${csv} (RHOAI 3.5 requires RHCL >= 1.3.5)"
        fi
      fi
    fi
  done

  for csv in "${csvs[@]}"; do
    if is_kuadrant_stack_csv "$csv"; then
      local minor
      minor=$(csv_minor "$csv")
      if (( minor > MAX_RHCL_MINOR )); then
        blocked=true
        if [[ -z "$reason" ]]; then
          reason="includes ${csv} (Kuadrant stack must stay on 1.3.x with RHCL 1.3.6)"
        fi
      fi
    fi
  done

  if $blocked; then
    echo "REJECT|$reason"
    return
  fi

  if $has_rhcl; then
    echo "APPROVE|RHCL 1.3.x install/upgrade"
    return
  fi

  # Dependency-only plans (authorino/limitador/dns) without rhcl in the same plan.
  local kuadrant_only=true
  for csv in "${csvs[@]}"; do
    is_kuadrant_stack_csv "$csv" || kuadrant_only=false
  done
  if $kuadrant_only && ((${#csvs[@]} > 0)); then
    echo "APPROVE|Kuadrant dependency operators at 1.3.x"
    return
  fi

  echo "SKIP|no RHCL/Kuadrant-stack CSVs in plan"
}

mapfile -t PENDING < <(
  oc get installplan -n "$NAMESPACE" -o json 2>/dev/null \
    | jq -r '.items[] | select(.spec.approved == false) | .metadata.name' \
    || true
)

if ((${#PENDING[@]} == 0)); then
  echo "No pending InstallPlans in ${NAMESPACE}."
  exit 0
fi

approved=0
rejected=0
skipped=0

for ip in "${PENDING[@]}"; do
  mapfile -t CSVS < <(
    oc get installplan "$ip" -n "$NAMESPACE" -o json \
      | jq -r '.spec.clusterServiceVersionNames[]?'
  )

  verdict=$(plan_verdict "${CSVS[@]}")
  action="${verdict%%|*}"
  detail="${verdict#*|}"

  csv_list=$(printf '%s ' "${CSVS[@]}")
  printf 'InstallPlan %-20s [%s] %s\n' "$ip" "$action" "$detail"
  printf '  CSVs: %s\n' "${csv_list:-<none>}"

  case "$action" in
    APPROVE)
      if $APPROVE; then
        oc patch installplan "$ip" -n "$NAMESPACE" --type=merge \
          -p '{"spec":{"approved":true}}' >/dev/null
        echo "  -> approved"
        ((approved++)) || true
      else
        echo "  -> run with --approve to apply"
      fi
      ;;
    REJECT)
      echo "  -> NOT approved (pin violation)"
      ((rejected++)) || true
      ;;
    *)
      echo "  -> left pending (not RHCL-related)"
      ((skipped++)) || true
      ;;
  esac
done

echo
echo "Summary: approved=${approved} rejected=${rejected} skipped=${skipped} (pending listed=${#PENDING[@]})"

if $APPROVE && (( rejected > 0 )); then
  echo "WARNING: Some plans were rejected. Do not patch them manually without checking CSV versions." >&2
  exit 1
fi

if ! $APPROVE && (( rejected > 0 )); then
  exit 1
fi
