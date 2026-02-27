---
name: setup-cluster
description: >
  Sets up Envoy Gateway infrastructure on a Kubernetes cluster. Handles both direct Helm install
  and GitOps (Flux/ArgoCD) deployment paths. Use when the user says "setup cluster X",
  "prepare X for envoy", "deploy envoy gateway on X", or "install envoy gateway".
license: Apache-2.0
metadata:
  author: vainkop
  version: 1.0.0
  tags: [infrastructure, envoy-gateway, setup]
---

# Setup Cluster for Envoy Gateway

This skill deploys Envoy Gateway and configures all cluster-level prerequisites for the
ingress-nginx to Envoy Gateway migration. It produces a working Gateway with TLS, DNS
integration, and all known production-hardening settings applied.

## Prerequisites

- `migration.config.yaml` must exist (copy from `migration.config.example.yaml` if missing)
- `kubectl` access to the target cluster (check `config.clusters[].context`)
- Helm v3.12+ installed (for Helm path)
- cert-manager already running on the cluster
- external-dns already running on the cluster

## Procedure

### Step 1: Deploy Envoy Gateway

Read `config.project.envoy_gateway_version` for the target version.
Read `config.advanced.namespace` for the namespace (default: `envoy-gateway-system`).
Read `config.advanced.node_selector` for node placement constraints.
Read `config.clusters[].arch` for the architecture (set `nodeSelector: kubernetes.io/arch`).

**Path A -- Direct Helm Install:**

```bash
helm install eg oci://docker.io/envoyproxy/gateway-helm \
  --version <config.project.envoy_gateway_version> \
  --namespace <config.advanced.namespace> \
  --create-namespace \
  --set config.envoyGateway.provider.kubernetes.deploy.replicas=<config.advanced.controller_replicas>
```

Verify: `kubectl get pods -n <namespace>` shows controller pod Running.

**Path B -- Flux GitOps:**

Create in `config.repos.infrastructure`:
1. `HelmRepository` pointing to `oci://docker.io/envoyproxy/gateway-helm`
2. `HelmRelease` in the envoy-gateway-system namespace with values for replicas and nodeSelector
3. `Kustomization` wiring the above together

Follow existing patterns in the infrastructure repo for HelmRelease structure.

**Path C -- ArgoCD GitOps:**

Create an `Application` resource targeting the Envoy Gateway Helm chart OCI URL with
appropriate values overrides for replicas and nodeSelector.

### Step 2: Create GatewayClass, EnvoyProxy, and Gateway

Apply the three core resources. See `examples/gateway/` for templates.

**GatewayClass:**
- `controllerName: gateway.envoyproxy.io/gatewayclass-controller`
- Reference the EnvoyProxy config via `parametersRef`

**EnvoyProxy:**
- Set `provider.kubernetes.envoyDeployment.replicas` to `config.advanced.proxy_replicas`
- Set `provider.kubernetes.envoyDeployment.pod.nodeSelector` from `config.advanced.node_selector`
- Set `provider.kubernetes.envoyService.externalTrafficPolicy: Local`
- Configure telemetry accessLog to include `%RESPONSE_CODE_DETAILS%` (see Step 7)

**Gateway:**
- Create in `config.advanced.namespace`
- Reference the GatewayClass
- Start with an HTTP listener on port 80 and HTTPS listener on port 443
- **CRITICAL**: Set `allowedRoutes.namespaces.from: All` on ALL listeners
  (default is `from: Same` which blocks HTTPRoutes from app namespaces)

Verify: `kubectl get gateway -n <namespace>` shows `Programmed: True`.
Verify: `kubectl get svc -n <namespace>` shows a LoadBalancer with an external IP assigned.

### Step 3: Create ClusterIssuer for cert-manager Gateway Shim

Read `config.tls.issuer_name` for the base name.
Create a new ClusterIssuer (e.g., `<issuer_name>-gateway`) with:

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: <issuer_name>-gateway
spec:
  acme:
    server: https://acme-v2.api.letsencrypt.org/directory
    privateKeySecretRef:
      name: <issuer_name>-gateway-account-key
    solvers:
      - http01:
          gatewayHTTPRoute:
            parentRefs:
              - name: <gateway-name>
                namespace: <config.advanced.namespace>
```

This uses the Gateway API solver instead of the nginx ingress solver.

Verify: `kubectl get clusterissuer <issuer_name>-gateway` shows `Ready: True`.

### Step 4: Enable cert-manager Gateway API Support

Update cert-manager Helm values to include:

```yaml
config:
  enableGatewayAPI: true
```

Do NOT use the deprecated `featureGates` approach -- it was removed in recent cert-manager versions.

After the Helm upgrade applies new Gateway API RBAC resources, **restart cert-manager pods**:

```bash
kubectl rollout restart deployment cert-manager -n cert-manager
```

This is required because cert-manager caches RBAC permissions at startup.

Verify: cert-manager logs show Gateway API controllers starting.

### Step 5: Add gateway-httproute to external-dns Sources

Update external-dns Helm values or configuration to include `gateway-httproute` in its `sources` list:

```yaml
sources:
  - ingress
  - gateway-httproute  # Add this
```

This tells external-dns to watch HTTPRoute resources for DNS record creation.

Verify: external-dns logs show it watching HTTPRoute resources.

### Step 6: Deploy ClientTrafficPolicy for Underscore Headers

**MANDATORY on every cluster.** Envoy rejects HTTP headers containing underscores by default
(returning 400). nginx allows them. Many CDN proxies, legacy clients, and third-party services
(e.g., server-side API callouts) send headers with underscores.

```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: ClientTrafficPolicy
metadata:
  name: allow-underscore-headers
  namespace: <config.advanced.namespace>
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: <gateway-name>
  headers:
    withUnderscoresAction: Allow
```

Note: Use `targetRefs` (plural list), not the deprecated `targetRef` (singular).

Verify: `kubectl get clienttrafficpolicy -n <namespace>` shows `Accepted: True`.

### Step 7: Configure Access Log Format

In the `EnvoyProxy` resource created in Step 2, ensure the telemetry section includes
`%RESPONSE_CODE_DETAILS%`:

```yaml
spec:
  telemetry:
    accessLog:
      settings:
        - format:
            type: Text
            text: |
              [%START_TIME%] "%REQ(:METHOD)% %REQ(X-ENVOY-ORIGINAL-PATH?:PATH)% %PROTOCOL%"
              %RESPONSE_CODE% %RESPONSE_CODE_DETAILS% %RESPONSE_FLAGS% %BYTES_RECEIVED%
              %BYTES_SENT% %DURATION% "%REQ(X-FORWARDED-FOR)%" "%REQ(USER-AGENT)%"
              "%UPSTREAM_HOST%"
```

Without `%RESPONSE_CODE_DETAILS%`, debugging proxy-level 400s (e.g., `http1.unexpected_underscore`,
`filter_chain_not_found`) is nearly impossible.

### Step 8: Verify All Components

Run the following verification checks:

```bash
# 1. Envoy Gateway controller is running
kubectl get pods -n <namespace> -l app.kubernetes.io/name=envoy-gateway

# 2. GatewayClass is accepted
kubectl get gatewayclass -o jsonpath='{.items[*].status.conditions[?(@.type=="Accepted")].status}'

# 3. Gateway is programmed
kubectl get gateway -n <namespace> -o jsonpath='{.items[*].status.conditions[?(@.type=="Programmed")].status}'

# 4. LoadBalancer has external IP
kubectl get svc -n <namespace> -l gateway.envoyproxy.io/owning-gateway-name

# 5. ClientTrafficPolicy is accepted
kubectl get clienttrafficpolicy -n <namespace>

# 6. ClusterIssuer is ready
kubectl get clusterissuer <issuer_name>-gateway

# 7. cert-manager has Gateway API support
kubectl logs deployment/cert-manager -n cert-manager | grep -i gateway

# 8. external-dns has gateway-httproute source
kubectl logs deployment/external-dns -n <external-dns-namespace> | grep -i gateway
```

Report results as a table:

| Check | Status | Details |
|-------|--------|---------|
| Envoy Gateway controller | PASS/FAIL | Pod count and status |
| GatewayClass accepted | PASS/FAIL | Condition message |
| Gateway programmed | PASS/FAIL | Condition message |
| LoadBalancer IP assigned | PASS/FAIL | IP address |
| ClientTrafficPolicy accepted | PASS/FAIL | underscore headers allowed |
| ClusterIssuer ready | PASS/FAIL | Issuer name and status |
| cert-manager Gateway API | PASS/FAIL | Log evidence |
| external-dns gateway source | PASS/FAIL | Log evidence |

## Common Issues

- **Gateway stuck on `Programmed: False`**: Check EnvoyProxy config for syntax errors,
  check if the namespace exists, check RBAC.
- **No LoadBalancer IP**: Cloud provider LB quota exhausted, or annotation issues.
  Check cloud-specific LB annotations in EnvoyProxy config.
- **cert-manager not issuing**: Forgot to restart pods after RBAC update (Step 4).
- **external-dns not creating records**: Missing `gateway-httproute` source, or RBAC
  missing for HTTPRoute resources.

## References

- `examples/gateway/` -- Ready-to-use GatewayClass, EnvoyProxy, Gateway, ClientTrafficPolicy, ClusterIssuer YAML
- `docs/cert-manager-gateway-setup.md` -- Detailed cert-manager integration guide
- `docs/gotchas.md` -- Full list of known issues
- `docs/debugging-underscore-headers.md` -- Underscore header debugging guide
- CLAUDE.md constraints: 1, 4, 9, 10, 11, 13, 14, 15
