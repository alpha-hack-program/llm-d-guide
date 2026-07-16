# Full MaaS Reset

> See also: [MaaS Demo](maas-demo.md) | [ExternalModel MaaS Demo](external-model-demo.md)

Use this when you want to wipe all demo state across both the [MaaS Demo](maas-demo.md) and
the [ExternalModel MaaS Demo](external-model-demo.md) and start from a clean slate.

The order matters: delete dependents before owners so the maas-controller can clean up the
Kuadrant resources it manages (AuthPolicies, TokenRateLimitPolicies, HTTPRoutes) before the
parent CRs disappear.

```bash
MODEL_NAMESPACE=llm-d-demo

# 1. MaaSAuthPolicies — each one owns Kuadrant AuthPolicy objects; delete first
oc delete maasauthpolicy --all -n models-as-a-service 2>/dev/null || true

# 2. MaaSSubscriptions — each one owns Kuadrant TokenRateLimitPolicy objects
oc delete maassubscription --all -n models-as-a-service 2>/dev/null || true

# 3. MaaSModelRefs — each one owns an HTTPRoute on the MaaS gateway
oc delete maasmodelref --all -n ${MODEL_NAMESPACE} 2>/dev/null || true

# 4. ExternalModels — removes ext_proc routing and credential-store entries
oc delete externalmodel --all -n ${MODEL_NAMESPACE} 2>/dev/null || true

# 5. ExternalModel credential secret
oc delete secret -n ${MODEL_NAMESPACE} -l inference.networking.k8s.io/bbr-managed=true \
  2>/dev/null || true

# 6. OpenShift Groups created by the demos (keeps cluster-admins and rhods-admins)
oc delete group freemium-users pro-users premium-users 2>/dev/null || true

# 7. (Optional) delete demo users — uncomment if you also want to remove the OCP user objects
# oc delete user alice bob charlie 2>/dev/null || true
# oc delete identity --all 2>/dev/null || true
```

Verify clean state:

```bash
oc get maasauthpolicy,maassubscription,maasmodelref -A
oc get externalmodel -A
oc get authpolicy,tokenratelimitpolicy -n ${MODEL_NAMESPACE}
oc get groups
```

All six lists should be empty (except the two system groups).
