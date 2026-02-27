---
name: pre-flight-check
description: >
  Verifies all cluster prerequisites are met before starting app migration. Runs 10 kubectl-based
  checks and reports READY or NOT READY for each. Use when "pre-flight check", "is cluster ready",
  "check prerequisites", "verify cluster setup", "can I start migrating".
license: Apache-2.0
metadata:
  author: vainkop
  version: 1.0.0
  tags: [pre-flight, prerequisites, readiness, verification]
---

# Pre-Flight Check for Migration Readiness

This skill verifies that all cluster-level prerequisites are in place before migrating any
application from ingress-nginx to Envoy Gateway. It runs 10 checks via `kubectl` and reports
a clear READY/NOT READY status for each, with fix instructions for any failures.

## Prerequisites

- `migration.config.yaml` must exist (read Gateway name, namespace, issuer name from config)
- `kubectl` access to the target cluster

## Procedure

Read `migration.config.yaml` to determine:
- `config.advanced.namespace` (default: `envoy-gateway-system`)
- `config.tls.issuer_name` (e.g., `letsencrypt-prod`)
- Gateway resource name (from config or discover via `kubectl get gateway -n <namespace>`)

### Check 1: Envoy Gateway Namespace and Pods Running

```bash
kubectl get pods -n <config.advanced.namespace> -l app.kubernetes.io/name=envoy-gateway
```

**READY**: At least one pod in `Running` state with `Ready` condition `True`.

**NOT READY**: No pods, pods in `CrashLoopBackOff`, or pods not ready.

**Fix**: Run `/setup-cluster` Step 1 to deploy Envoy Gateway.

### Check 2: GatewayClass Accepted

```bash
kubectl get gatewayclass -o json | \
  jq '.items[] | select(.spec.controllerName == "gateway.envoyproxy.io/gatewayclass-controller") | {name: .metadata.name, accepted: .status.conditions[] | select(.type == "Accepted") | .status}'
```

**READY**: GatewayClass exists with `Accepted: True` condition.

**NOT READY**: GatewayClass missing, or `Accepted: False`.

**Fix**: Run `/setup-cluster` Step 2. Check EnvoyProxy parametersRef is valid.

### Check 3: Gateway Programmed

```bash
kubectl get gateway -n <config.advanced.namespace> -o json | \
  jq '.items[] | {name: .metadata.name, programmed: .status.conditions[] | select(.type == "Programmed") | .status, listeners: (.spec.listeners | length)}'
```

**READY**: Gateway exists with `Programmed: True` condition.

**NOT READY**: Gateway missing, `Programmed: False`, or no listeners defined.

**Fix**: Run `/setup-cluster` Step 2. Check GatewayClass reference is correct.

### Check 4: LoadBalancer IP Assigned

```bash
kubectl get svc -n <config.advanced.namespace> \
  -l gateway.envoyproxy.io/owning-gateway-name \
  -o jsonpath='{.items[*].status.loadBalancer.ingress[*].ip}'
```

**READY**: At least one Service of type LoadBalancer with an external IP assigned.

**NOT READY**: No LoadBalancer Service, or IP is `<pending>`.

**Fix**: Check cloud provider LoadBalancer quota. Verify Service annotations for
cloud-specific LB configuration. Check EnvoyProxy `provider.kubernetes.envoyService` settings.

Record the Envoy LB IP for use in migration testing.

### Check 5: ClientTrafficPolicy with Underscore Header Fix

```bash
kubectl get clienttrafficpolicy -n <config.advanced.namespace> -o json | \
  jq '.items[] | {name: .metadata.name, underscoreAction: .spec.headers.withUnderscoresAction, accepted: .status.conditions[] | select(.type == "Accepted") | .status}'
```

**READY**: A ClientTrafficPolicy exists targeting the Gateway with
`headers.withUnderscoresAction: Allow` and `Accepted: True`.

**NOT READY**: No ClientTrafficPolicy, or `withUnderscoresAction` is not set to `Allow`,
or policy not accepted.

**Fix**: Run `/setup-cluster` Step 6. This is MANDATORY -- without it, any request
containing headers with underscores (common from CDN proxies and third-party integrations)
will receive a 400 error. nginx allows underscores by default; Envoy rejects them.

### Check 6: cert-manager Has Gateway API Support

```bash
# Check cert-manager deployment for Gateway API enablement
kubectl get deployment cert-manager -n cert-manager -o json | \
  jq '.spec.template.spec.containers[0].args'

# Check cert-manager logs for Gateway API controllers
kubectl logs deployment/cert-manager -n cert-manager --tail=100 | grep -i "gateway"
```

**READY**: cert-manager logs show Gateway API controllers started, or cert-manager
Helm values include `config.enableGatewayAPI: true`.

**NOT READY**: No Gateway API log messages, or using the deprecated `featureGates` approach.

**Fix**: Run `/setup-cluster` Step 4. Update cert-manager Helm values to include
`config.enableGatewayAPI: true` (NOT `featureGates`), then restart cert-manager pods.

### Check 7: ClusterIssuer for Gateway Ready

```bash
kubectl get clusterissuer -o json | \
  jq '.items[] | select(.spec.acme.solvers[].http01.gatewayHTTPRoute != null) | {name: .metadata.name, ready: .status.conditions[] | select(.type == "Ready") | .status}'
```

**READY**: A ClusterIssuer exists that uses `http01.gatewayHTTPRoute` solver with `Ready: True`.

**NOT READY**: No gateway-aware ClusterIssuer, or it is not Ready.

**Fix**: Run `/setup-cluster` Step 3. Create a ClusterIssuer with `gatewayHTTPRoute`
solver referencing your Gateway.

### Check 8: external-dns Has gateway-httproute Source

```bash
# Check external-dns deployment args for gateway-httproute source
kubectl get deployment -n <external-dns-namespace> -l app.kubernetes.io/name=external-dns -o json | \
  jq '.items[0].spec.template.spec.containers[0].args' | grep -i "gateway"

# Check external-dns logs
kubectl logs deployment/external-dns -n <external-dns-namespace> --tail=100 | grep -i "gateway\|httproute"
```

Note: The external-dns namespace varies by installation. Common namespaces include
`external-dns`, `kube-system`, and `default`. Check `migration.config.yaml` or discover via:

```bash
kubectl get deployment -A -l app.kubernetes.io/name=external-dns
```

**READY**: external-dns has `--source=gateway-httproute` in its args or configuration.

**NOT READY**: external-dns does not have `gateway-httproute` as a source.

**Fix**: Run `/setup-cluster` Step 5. Add `gateway-httproute` to external-dns sources
via Helm values or deployment args.

### Check 9: Access Log Includes RESPONSE_CODE_DETAILS

```bash
kubectl get envoyproxy -n <config.advanced.namespace> -o json | \
  jq '.items[] | {name: .metadata.name, accessLogFormat: .spec.telemetry.accessLog}'
```

**READY**: EnvoyProxy telemetry config includes `%RESPONSE_CODE_DETAILS%` in the
access log format string.

**NOT READY**: No access log configured, or `%RESPONSE_CODE_DETAILS%` is missing.

**Fix**: Run `/setup-cluster` Step 7. Without this field, debugging proxy-level 400/404
errors is nearly impossible. It shows exactly why Envoy rejected a request (e.g.,
`http1.unexpected_underscore`, `filter_chain_not_found`).

### Check 10: Gateway Listeners Have allowedRoutes from: All

```bash
kubectl get gateway -n <config.advanced.namespace> -o json | \
  jq '.items[].spec.listeners[] | {name: .name, hostname: .hostname, allowedRoutes: .allowedRoutes}'
```

**READY**: ALL listeners have `allowedRoutes.namespaces.from: All`.

**NOT READY**: Any listener has `from: Same` (the default) or `from: Selector`.

**Fix**: Update the Gateway spec to set `allowedRoutes.namespaces.from: All` on every listener.
The default `from: Same` only allows HTTPRoutes in the Gateway's own namespace, which blocks
all app HTTPRoutes (since apps live in their own namespaces).

## Output: Pre-Flight Report

```
=== Pre-Flight Check Report ===

Cluster:  <cluster-name>
Context:  <kubectl-context>
Date:     <timestamp>

| # | Check | Status | Details |
|---|-------|--------|---------|
| 1 | Envoy Gateway pods | READY/NOT READY | <pod count>, <status> |
| 2 | GatewayClass accepted | READY/NOT READY | <name>, <condition> |
| 3 | Gateway programmed | READY/NOT READY | <name>, <listener count> |
| 4 | LoadBalancer IP | READY/NOT READY | <IP address or pending> |
| 5 | Underscore header fix | READY/NOT READY | <CTP name>, <action> |
| 6 | cert-manager gateway-shim | READY/NOT READY | <evidence> |
| 7 | ClusterIssuer for Gateway | READY/NOT READY | <issuer name>, <status> |
| 8 | external-dns gateway source | READY/NOT READY | <source list> |
| 9 | Access log RESPONSE_CODE_DETAILS | READY/NOT READY | <format string presence> |
| 10 | Gateway allowedRoutes from: All | READY/NOT READY | <listener details> |

Overall: <X/10 READY>

<If all 10 READY>
Cluster is READY for migration. Proceed with /migrate-app or /analyze-ingress.

<If any NOT READY>
Cluster is NOT READY. Fix the items above before starting migration.
Run /setup-cluster to address missing infrastructure.
```

## Notes

- Checks 1-4 are hard prerequisites. If any fail, no migration can proceed.
- Checks 5-10 are critical for production correctness. Migration may technically work
  without them, but will cause subtle failures (400 errors, broken auth, no debugging
  capability, cert renewal failures).
- This skill is read-only. It does not make any changes to the cluster.
- Re-run after `/setup-cluster` to verify all fixes were applied correctly.

## References

- `/setup-cluster` -- Skill to fix any NOT READY items
- `docs/gotchas.md` -- Detailed explanation of each prerequisite
- `docs/debugging-underscore-headers.md` -- Why Check 5 matters
- `docs/cert-manager-gateway-setup.md` -- cert-manager integration details
- CLAUDE.md constraints: 1, 9, 10, 11, 13, 14, 15
