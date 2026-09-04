# RHCL version pin (1.3.x) — install guardrails

> Part of the [llm-d-guide Co-pilot Runbook](../../AGENTS.md).
> See [Phase 3](../phases/03-operators-rhoai.md) and [MaaS troubleshooting](maas-troubleshooting.md).

## Why pin?

RHOAI 3.5 MaaS requires **Red Hat Connectivity Link (RHCL) 1.3.5+** (Wasm shim bug fixed in 1.3.5).
This guide pins the subscription to **1.3.6** on the `stable` channel for reproducible installs.

The Subscription in `gitops/operators/connectivity-link/operator.yaml` sets:

- `startingCSV: rhcl-operator.v1.3.6`
- `installPlanApproval: Manual`

**Important:** `startingCSV` only selects the *initial* install target. On channel `stable`,
OLM can still propose **upgrade** InstallPlans to a newer 1.3.x CSV. Approving arbitrary
InstallPlans in `openshift-operators` can also pull in unintended operator upgrades.

## Safe InstallPlan approval (Phase 3)

**Never** bulk-approve every pending InstallPlan in `openshift-operators`.

Use the guard script instead:

```bash
# List pending plans and whether each is safe to approve
./scripts/approve-rhcl-installplan.sh

# Approve only RHCL / Kuadrant-stack plans that stay on 1.3.x (>= 1.3.5)
./scripts/approve-rhcl-installplan.sh --approve
```

After approval, verify:

```bash
oc get csv -n openshift-operators | grep -E 'rhcl|authorino|limitador|dns'
# RHCL must be rhcl-operator.v1.3.6 (or another 1.3.x CSV >= 1.3.5)
```

Re-run `./scripts/check-operators.sh` — it warns if RHCL is below 1.3.5 or above 1.3.x.

### What the script rejects

- Any InstallPlan that installs `rhcl-operator` below **v1.3.5**
- Any InstallPlan that installs `rhcl-operator.v1.4.x` or higher (stay on 1.3.x line)
- Kuadrant-stack CSVs (`authorino-operator`, `limitador-operator`, `dns-operator`) at **1.4.x**
  when pinning the 1.3.x line

### What assistants must not do

- `oc get installplan ... | xargs oc patch ... approved:true` across all operators
- Auto-approve every Manual InstallPlan during Phase 3 without reading CSV names

Other operators (COO, Tempo, etc.) have their own namespaces and pinned versions — approve those
**individually** per their phase guide, not via a global openshift-operators loop.

---

## Downgrade procedure (< 1.3.5 or accidental 1.4.x → 1.3.6)

> **Impact:** MaaS auth and rate limiting stop working until Kuadrant operands and
> Phase 6 Authorino TLS are re-verified. Schedule a maintenance window.

### 1. Record current state

```bash
oc get csv -n openshift-operators | grep -E 'rhcl|authorino|limitador|dns'
oc get subscription -n openshift-operators | grep -E 'rhcl|authorino|limitador|dns'
./scripts/approve-rhcl-installplan.sh
```

### 2. Remove Kuadrant operands (keeps CRDs)

```bash
oc delete kuadrant kuadrant -n kuadrant-system --wait=true --ignore-not-found=true
oc get pods -n kuadrant-system
```

### 3. Remove wrong-version operator subscriptions and CSVs

```bash
for sub in rhcl-operator authorino-operator limitador-operator dns-operator; do
  oc delete subscription "$sub" -n openshift-operators --ignore-not-found=true
done
oc delete csv -n openshift-operators -l operators.coreos.com/kuadrant-operator
oc delete csv -n openshift-operators \
  $(oc get csv -n openshift-operators -o name | grep -E 'rhcl|authorino|limitador|dns') \
  --ignore-not-found=true
```

### 4. Re-apply pinned subscription

```bash
oc apply -f gitops/operators/connectivity-link/operator.yaml
./scripts/approve-rhcl-installplan.sh --approve
oc wait --for=jsonpath='{.status.phase}'=Succeeded \
  csv/rhcl-operator.v1.3.6 -n openshift-operators --timeout=600s
```

### 5. Re-create Kuadrant CR and re-verify Phase 6

```bash
helm template gitops/instance/maas/connectivity-link \
  --name-template maas-connectivity-link | oc apply -f -
oc get pods -n kuadrant-system
```

Re-run [Phase 6 Step 4](06-maas.md) (Authorino TLS) if API keys return HTTP 500.

---

## Upgrading from 3.4

If you upgraded RHOAI from 3.4 using [migration-3.4-to-3.5.md](migration-3.4-to-3.5.md), verify RHCL
is still on 1.3.5+ after the migration. Re-run `./scripts/check-operators.sh` and the Phase 6 MaaS
smoke test.
