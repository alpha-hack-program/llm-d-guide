# OLMv1 on OCP 4.21+ — Operator Install Method

> Part of the [llm-d-guide](../../README.md). See the
> [Phase Map](../../AGENTS.md#phase-map) for the full install sequence.

## Background

OpenShift Container Platform 4.21 introduces **OLMv1** (Operator Lifecycle Manager v1) as the default operator management system. OLMv0 (the classic `Subscription` + `InstallPlan` + `CSV` flow) remains fully supported through the OCP 4 lifecycle but is deprecated.

> **Important — OCP 4.21 web console limitation:** On OCP 4.21, the web console's **Installed Operators** page only lists OLMv0-installed operators (CSVs). Operators installed via OLMv1 (`ClusterExtension`) are functional but invisible in the console UI. For this reason, **this guide uses OLMv0 for all operators on both OCP 4.20 and 4.21**. OLMv1 install paths (`cluster-extension.yaml`, `--set olmVersion=v1`) are shipped in every operator directory for forward compatibility — use them when a future OCP release adds console support for OLMv1 operators.

This guide ships both install methods:
- **OCP 4.20 and 4.21** — OLMv0 (`operator.yaml` / Helm without `--set olmVersion=v1`) — **recommended**
- **Future OCP** — OLMv1 (`cluster-extension.yaml` / Helm with `--set olmVersion=v1`) — for forward compatibility

## Key Differences

| Aspect | OLMv0 (OCP 4.20) | OLMv1 (OCP 4.21+) |
|---|---|---|
| Install API | `Subscription` + `InstallPlan` + `CSV` + `OperatorGroup` | `ClusterExtension` (single resource) |
| API group | `operators.coreos.com/v1alpha1` | `olm.operatorframework.io/v1` |
| Scope | Namespace or cluster-scoped | Always cluster-scoped |
| Security model | Automatic broad permissions | Explicit `ServiceAccount` + `ClusterRoleBinding` |
| Catalog resource | `CatalogSource` (in `openshift-marketplace`) | `ClusterCatalog` (cluster-scoped) |
| Version control | `startingCSV` pin | Semver ranges, channel selection |
| Approval | `installPlanApproval: Manual/Automatic` | Continuous reconciliation (no InstallPlan) |
| Wait condition | `CSV` phase = `Succeeded` | `ClusterExtension` condition `Installed = True` |

## AllNamespaces Install Mode Requirement

OLMv1 `ClusterExtension` **only supports bundles that declare `AllNamespaces` install mode**. Bundles limited to `OwnNamespace` or `SingleNamespace` fail with:

```
unsupported bundle: bundle does not support AllNamespaces install mode
```

This constraint means that **not all operators in this guide can use OLMv1** on OCP 4.21+. The compatibility matrix (validated on OCP 4.21.18):

| Operator | OLMv1 compatible | Usable with OLMv1 in this guide | Install method on 4.21+ |
|---|---|---|---|
| cert-manager | Yes | Yes | Helm `--set olmVersion=v1` |
| Connectivity Link (RHCL) | **No** — `olm.package.required` deps | **No** | `oc apply -k` (always OLMv0) |
| Tempo | Yes | **No** — RHOAI detects via CSV only | OLMv0 (`oc apply -k`) |
| OpenTelemetry | Yes | **No** — RHOAI detects via CSV only | OLMv0 (`oc apply -k`) |
| RHOAI | Yes | Yes | Helm `--set olmVersion=v1` |
| COO | Yes | Yes | `cluster-extension.yaml` |
| **NFD** | **No** — OwnNamespace only | **No** | `install.sh` (always OLMv0) |
| **NVIDIA GPU** | **No** — OwnNamespace only | **No** | `install.sh` (always OLMv0) |
| **LeaderWorkerSet** | **No** — OwnNamespace only | **No** | `oc apply -k` (always OLMv0) |

The `install.sh` scripts for NFD and NVIDIA always use OLMv0 regardless of OCP version. LeaderWorkerSet must be installed via `oc apply -k gitops/operators/leader-worker-set` (which applies the OLMv0 `operator.yaml`).

The `cluster-extension.yaml` files for these three operators are kept in the repo for forward compatibility — they will work once the upstream bundles add AllNamespaces support.

Additionally, **Tempo and OpenTelemetry must also use OLMv0** in this guide. While their bundles support AllNamespaces (OLMv1 works technically), RHOAI 3.5's monitoring controller detects these operators by checking for a CSV — it does not recognize OLMv1 ClusterExtensions. Installing Tempo or OpenTelemetry via OLMv1 causes the monitoring stack precondition to fail with `"Tempo operator must be installed for traces configuration"`, preventing TempoMonolithic creation.

Until RHOAI adds OLMv1 operator detection, use OLMv0 for Tempo and OpenTelemetry.

Additionally, **Connectivity Link (RHCL) must also use OLMv0**. The RHCL v1.4.x bundle declares `olm.package.required` dependencies, which OLMv1 does not support. Installing via `ClusterExtension` fails with `"bundle has a dependency declared via property 'olm.package.required' which is currently not supported"`. Always use `oc apply -k gitops/operators/connectivity-link` (OLMv0) regardless of OCP version.

## ClusterExtension Anatomy

A `ClusterExtension` replaces four OLMv0 resources (`Subscription`, `InstallPlan`, `CSV`, `OperatorGroup`) with one:

```yaml
apiVersion: olm.operatorframework.io/v1
kind: ClusterExtension
metadata:
  name: rhcl-operator
spec:
  namespace: openshift-operators               # where operator pods run
  serviceAccount:
    name: rhcl-installer                       # pre-created SA with RBAC
  source:
    sourceType: Catalog
    catalog:
      packageName: rhcl-operator               # same as OLMv0 Subscription .spec.name
      channels:                                # optional — omit to use default channel
      - stable
  install:
    preflight:
      crdUpgradeSafety:
        enforcement: Strict                    # safety check for CRD schema changes
```

> **`crdUpgradeSafety` schema note:** The field changed from `disabled: true/false` to `enforcement: None/Strict`. Using the old `disabled` field on current OCP 4.21 produces a validation error: `spec.install.preflight.crdUpgradeSafety.enforcement: Required value`.

### Required Supporting Resources

Unlike OLMv0, OLMv1 does **not** auto-grant permissions. Each operator needs:

1. **Namespace** — same as before (unchanged)
2. **ServiceAccount** — pre-created in the operator namespace
3. **ClusterRoleBinding** — binds the SA to a `ClusterRole` with sufficient permissions

This guide uses `cluster-admin` for the SA, which matches the effective permissions OLMv0 auto-grants. Production environments should scope the RBAC to the specific resources each operator manages.

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: nfd-installer
  namespace: openshift-nfd
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: nfd-installer
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
- kind: ServiceAccount
  name: nfd-installer
  namespace: openshift-nfd
```

## Catalog Mapping

OLMv1 uses `ClusterCatalog` resources instead of `CatalogSource`. The default catalogs on OCP 4.21:

| OLMv0 `CatalogSource` | OLMv1 `ClusterCatalog` | Operators |
|---|---|---|
| `redhat-operators` | `openshift-redhat-operators` | NFD, RHCL, Tempo, OTel, COO, RHOAI, cert-manager, LWS |
| `certified-operators` | `openshift-certified-operators` | NVIDIA GPU Operator |

The `ClusterExtension` does not explicitly reference a catalog — the OLMv1 resolver finds the package across all active `ClusterCatalog` resources automatically.

## How This Guide Handles Both Paths

### Detecting the OCP Version

```bash
OCP_MINOR=$(oc version -o json | jq -r '.openshiftVersion' | cut -d. -f2)
```

This is auto-derived at Phase 0 and determines the install method for all subsequent phases.

### Plain-YAML Operators

Each operator directory contains both files:

```
gitops/operators/<operator>/
  operator.yaml              # OLMv0 — Namespace + OperatorGroup + Subscription
  cluster-extension.yaml     # OLMv1 — Namespace + ServiceAccount + ClusterRoleBinding + ClusterExtension
```

Apply the correct file based on OCP version:

```bash
# OCP 4.20 (OLMv0):
oc apply -f gitops/operators/<operator>/operator.yaml

# OCP 4.21+ (OLMv1):
oc apply -f gitops/operators/<operator>/cluster-extension.yaml
```

### Helm Charts (cert-manager, RHOAI)

Pass `--set olmVersion=v1` on OCP 4.21+:

```bash
# OCP 4.20 (OLMv0) — default:
helm template rhoai-operator ./gitops/operators/rhoai | oc apply -f -

# OCP 4.21+ (OLMv1):
helm template rhoai-operator ./gitops/operators/rhoai --set olmVersion=v1 | oc apply -f -
```

The Helm chart renders either a `Subscription` + `OperatorGroup` (v0) or a `ServiceAccount` + `ClusterRoleBinding` + `ClusterExtension` (v1) based on this value.

### install.sh Scripts (NFD, NVIDIA)

The `install.sh` scripts for NFD and NVIDIA **always use OLMv0** because these operators do not support `AllNamespaces` install mode (required by OLMv1):

```bash
./gitops/operators/nfd/install.sh      # always OLMv0 (Subscription)
./gitops/operators/nvidia/install.sh   # always OLMv0 (Subscription)
```

Both scripts query `packagemanifest` for the channel/CSV and apply `operator.yaml` regardless of OCP version. When these bundles add AllNamespaces support upstream, the scripts can be updated to use OLMv1 on 4.21+.

## Wait Conditions

The wait condition after installing an operator differs between OLMv0 and OLMv1:

```bash
# OCP 4.20 — wait for CSV:
oc get csv -n <namespace> -w
# Look for: phase = Succeeded

# OCP 4.21+ — wait for ClusterExtension:
oc get clusterextension <name> -w
# Look for: Installed condition = True
```

Programmatic check for OLMv1:

```bash
oc wait --for=condition=Installed clusterextension/<name> --timeout=300s
```

## Operator Reference

| Operator | Package Name | OLMv1 on 4.21+ | Namespace |
|---|---|---|---|
| cert-manager | `openshift-cert-manager-operator` | Helm (`--set olmVersion=v1`) | `cert-manager-operator` |
| Connectivity Link | `rhcl-operator` | OLMv0 only (`olm.package.required` deps) | `openshift-operators` |
| COO | `cluster-observability-operator` | `cluster-extension.yaml` | `openshift-cluster-observability-operator` |
| RHOAI | `rhods-operator` | Helm (`--set olmVersion=v1`) | `redhat-ods-operator` |
| Tempo | `tempo-product` | OLMv0 only (RHOAI CSV check) | `openshift-tempo-operator` |
| OpenTelemetry | `opentelemetry-product` | OLMv0 only (RHOAI CSV check) | `openshift-opentelemetry-operator` |
| NFD | `nfd` | OLMv0 only (OwnNamespace) | `openshift-nfd` |
| NVIDIA GPU | `gpu-operator-certified` | OLMv0 only (OwnNamespace) | `nvidia-gpu-operator` |
| LeaderWorkerSet | `leader-worker-set` | OLMv0 only (OwnNamespace) | `openshift-lws-operator` |

## OLMv0 Support Status

OLMv0 (`Subscription` + `CSV` + `InstallPlan`) is **fully supported throughout the OCP 4 lifecycle**. There is no deprecation warning on OCP 4.21. Both OLM systems coexist and work correctly side by side.

Using OLMv0 for NFD, NVIDIA, and LeaderWorkerSet on OCP 4.21+ is the correct and supported approach — not a workaround.

## In-Place Migration from OLMv0 to OLMv1

**In-place migration is not supported.** OLMv1 uses Helm internally to manage operator resources. When it encounters pre-existing CRDs (created by OLMv0), it rejects them with:

```
CustomResourceDefinition '<name>' already exists in namespace '' and cannot be managed by operator-controller
```

This is not a label or annotation issue — it is an internal Helm release ownership check. Removing OLMv0 labels (`olm.managed`, `operators.coreos.com/...`) and adding Helm annotations (`meta.helm.sh/release-name`, `app.kubernetes.io/managed-by: Helm`) does not resolve it. Deleting the CRDs would work but cascade-deletes all CR instances (e.g. TempoMonolithic, TempoStack) — unacceptable in production.

**Consequence for this guide:** Operators installed via OLMv0 must stay on OLMv0 for the lifetime of the cluster. OLMv1 (`cluster-extension.yaml`) is only for **fresh installs** where no CRDs from the operator exist yet. Do not attempt to migrate a running operator from OLMv0 to OLMv1.

> Validated on OCP 4.21.18 with Tempo Operator — deleting Subscription + CSV + OperatorGroup and applying ClusterExtension failed on CRD ownership. Rolled back to OLMv0 successfully; operator and instances unaffected.

## Forward-Looking: OCP 4.22+

**OwnNamespace/SingleNamespace support in OLMv1:** The `NewOLMOwnSingleNamespace` feature gate is promoted to GA in OCP 4.22 ([openshift/api#2527](https://github.com/openshift/api/pull/2527)). Once on 4.22+, operators like NFD, NVIDIA, and LeaderWorkerSet should be installable via `ClusterExtension` using a `watchNamespace` field — no feature gate required. The `cluster-extension.yaml` files kept in this repo for those operators will become usable at that point (with `watchNamespace` added).

> **Tech Preview workaround on 4.21:** The same feature is available as Tech Preview via the `TechPreviewNoUpgrade` feature set. This is **not recommended** — it is a one-way gate that blocks all future cluster upgrades and enables every other Tech Preview feature simultaneously.

**CatalogSource removal:** Red Hat has indicated that the Marketplace `CatalogSource` resources (used by OLMv0) may be removed in a future OCP release. When that happens:

- All `packagemanifest` lookups will stop working
- `Subscription`-based installs will no longer resolve packages
- Migration to `ClusterExtension` CRs will be mandatory

This guide's OLMv1 path (`cluster-extension.yaml` files and `--set olmVersion=v1`) is forward-compatible with that change. The OLMv0 path (`operator.yaml`) will require update in a future guide revision.

## Troubleshooting

| Symptom | Cause | Resolution |
|---|---|---|
| `ClusterExtension` stuck in `Progressing` | ServiceAccount missing or insufficient RBAC | Verify SA exists and has `cluster-admin` binding |
| `no package found` error | ClusterCatalog not available or package name mismatch | `oc get clustercatalog` — all should show `Available`; verify `packageName` matches the catalog entry |
| Both `Subscription` and `ClusterExtension` exist for same operator | Mixed install — one blocks the other | Delete the one you don't want; never manage the same operator with both OLM versions |
| CRD upgrade safety check blocks update | Schema change detected in CRD | Review the change; if safe, set `install.preflight.crdUpgradeSafety.enforcement: None` temporarily |
| `unsupported bundle: bundle does not support AllNamespaces install mode` | Operator bundle only supports `OwnNamespace` | Use OLMv0 (`operator.yaml` / `install.sh`) — see AllNamespaces compatibility table above |
| `spec.install.preflight.crdUpgradeSafety.enforcement: Required value` | Old `disabled: true/false` field used | Replace `disabled: false` with `enforcement: Strict` (or `enforcement: None` to skip checks) |
| `ClusterExtension` shows `Installed=True` but no pods running | Namespace does not exist or SA lacks permissions in target namespace | Ensure the namespace was created before applying the ClusterExtension |
| `already exists and cannot be managed by operator-controller` | CRDs were created by OLMv0 — in-place migration is not supported | Stay on OLMv0 for this operator; OLMv1 is only for fresh installs without pre-existing CRDs |
| `Tempo operator must be installed for traces configuration` | RHOAI monitoring controller detects Tempo/OTel via CSV only — OLMv1 installs are invisible | Use OLMv0 for Tempo and OpenTelemetry until RHOAI adds OLMv1 awareness |

## References

- [OLMv1 Documentation (OCP 4.21)](https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html/operators/olm-v1)
- [Extensions Guide (OCP 4.21)](https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html-single/extensions/index)
- [ClusterExtension API Reference](https://docs.redhat.com/en/documentation/openshift_container_platform/4.19/html/operatorhub_apis/clusterextension-olm-operatorframework-io-v1)
