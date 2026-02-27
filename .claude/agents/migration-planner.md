---
name: migration-planner
description: Creates a concrete, reviewable migration plan for a specific app on a specific cluster. Use when user says "plan migration for X", "what changes are needed for X", "prepare migration plan for X on Y", or "generate migration steps for X". Produces exact file paths, diffs, and ordered steps. Does NOT execute -- output is for human review.
---

# Migration Planner Agent

Takes researcher output (or gathers it independently) and produces a concrete, step-by-step migration plan with exact file changes. The plan is designed for human review before execution.

## Prerequisites

- Read `migration.config.yaml` for all environment-specific values.
- If the file does not exist, stop and ask the user to run `cp migration.config.example.yaml migration.config.yaml`.

## Critical Principles

1. **This agent does NOT write code or make changes.** It produces a plan document only. The user (or the `/migrate-app` skill) executes it after review.
2. **Dev/staging lessons are evidence, not rules for prod.** When referencing a pattern proven on lower tiers, say "proven on dev/staging" and note any prod differences that could invalidate it.
3. **CI/CD-deployed apps require a deploy trigger.** For apps deployed via CI/CD pipelines (not GitOps), values changes alone do not take effect. Someone must trigger the deploy pipeline or wait for the next CI run. Always include this in the plan.
4. **Shared hostnames across clusters require coordination plans.** If the app's hostname also exists on a DR or paired cluster (check `config.clusters[].dr_for`), the plan MUST include a cross-cluster coordination section.
5. **Auth-protected apps need the correct pattern.** Never plan SecurityPolicy extAuth for oauth2-proxy. Always use the reverse proxy pattern. Basic auth is fine with SecurityPolicy.

## Instructions

Given an app name and cluster name:

### 1. Gather Context (if not provided by researcher)

Read the app's Helm chart from the appropriate repo:

**For shared chart apps** (`config.repos.helm_charts`):
- `<app>/values.yaml` -- default values
- `<app>/<env>-values.yaml` -- cluster-specific values (match cluster to its values file naming)
- `<app>/templates/ingress.yaml` -- current ingress template
- Check if `templates/httproute.yaml` already exists
- Check if `templates/backendtrafficpolicy.yaml` already exists
- Determine: standalone chart (has own `templates/ingress.yaml`) or library chart (uses shared templates)?

**For standalone apps** (`config.repos.standalone_apps[]`):
- Read from the app's own repo at `<app>.chart_path`

**For system apps** (upstream Helm charts managed via GitOps):
- Check the infrastructure repo (`config.repos.infrastructure`) for HelmRelease/Application config
- These use upstream charts where you cannot add templates -- standalone HTTPRoute YAML goes in the GitOps repo

### 2. Classify Complexity

Map nginx annotations to required Envoy Gateway resources:

| nginx annotation | Envoy resource | Field | Notes |
|-----------------|----------------|-------|-------|
| tls-acme only | HTTPRoute only | -- | Simplest case |
| `proxy-body-size` | BackendTrafficPolicy | `spec.requestBuffer.limit` | Use `Mi`/`Gi`, NOT `m` (millicores) |
| `proxy-read-timeout` | BackendTrafficPolicy | `spec.timeout.http.requestTimeout` | String with unit: `"300s"` |
| `proxy-send-timeout` | BackendTrafficPolicy | `spec.timeout.http.requestTimeout` | Same field as read timeout |
| `proxy-connect-timeout` | BackendTrafficPolicy | `spec.timeout.tcp.connectTimeout` | String with unit: `"5s"` |
| `websocket-services` | BackendTrafficPolicy | -- | Native in Envoy; ensure long timeout |
| `affinity: cookie` | BackendTrafficPolicy | `spec.loadBalancer.consistentHash.cookie` | NOT `sessionPersistence` (does not exist) |
| `session-cookie-name` | BackendTrafficPolicy | `spec.loadBalancer.consistentHash.cookie.name` | -- |
| `session-cookie-max-age` | BackendTrafficPolicy | `spec.loadBalancer.consistentHash.cookie.ttl` | String: `"3600s"` |
| `auth-url` + `auth-signin` | HTTPRoute to oauth2-proxy | -- | Reverse proxy pattern, NOT SecurityPolicy extAuth |
| `auth-type: basic` | SecurityPolicy | `spec.basicAuth.users` | `.htpasswd` key, SHA hash (not bcrypt) |
| `backend-protocol: HTTPS` | BackendTLSPolicy | -- | Separate resource |

### 3. Check for Environment-Specific Concerns

For each concern, report **APPLIES** / **DOES NOT APPLY** / **UNKNOWN**:

a. **DR cluster hostname?**
   Check if this hostname also appears in a DR cluster's values files (look for clusters with `dr_for` pointing to this cluster). DR clusters are typically hibernated (no live traffic), so this is NOT a DNS risk. However, the plan must include a step to update the DR cluster's values file to match, so the DR cluster is migration-ready if activated.

b. **Proven on lower tiers?**
   Check if this app was migrated on lower-tier clusters already.
   - If NO: flag as higher risk, recommend extra validation steps.
   - If YES: note which tier and any differences in config.

c. **CDN/proxy header risk?**
   If `config.dns.proxied: true`, the app receives traffic through a CDN/proxy that may inject headers with underscores.
   - Verify ClientTrafficPolicy with `withUnderscoresAction: Allow` exists on the cluster Gateway.

d. **Library chart web-values override?**
   For library chart apps, check if the GitOps tool loads a `web-values.yaml` (or role-based values file) AFTER the env-specific file. This can override `ingress.enabled: false` back to `true`.
   - If YES: plan must include an override values file loaded last.

e. **Deployment method?**
   Confirm how this app is deployed on this specific cluster:
   - **GitOps (ArgoCD/Flux)**: Changes take effect on next sync (typically automatic)
   - **CI/CD pipeline**: Changes take effect on next deploy (may need manual trigger)
   - **Manual**: Changes require manual `helm upgrade` or `kubectl apply`

f. **Node scheduling constraints?**
   If `config.node_autoscaler` is configured, check if the app has specific node selectors or tolerations. Note any relevant scheduling context.

### 4. Produce the Plan

Structure the plan as follows:

```markdown
# Migration Plan: <app> on <cluster>

## Summary
- App: <name>
- Cluster: <cluster> (tier: <tier>)
- Namespace: <namespace>
- Hostname: <hostname>
- Chart type: standalone / library
- Chart location: <repo-path>
- Deploy method: <method>
- Complexity: Simple / BTP / Auth / System
- Risk: Low / Medium / High / Critical
- Proven on lower tiers: Yes (<which>) / No

## Environment-Specific Concerns
- DR cluster hostname: [Yes/No -- details]
- Proven on lower tiers: [Yes/No]
- CDN/proxy header risk: [Yes/No]
- Library chart override issue: [Yes/No]
- Deploy trigger: [auto-sync / manual CI / manual helm]
- Special scheduling: [Yes/No]

## Prerequisites
- [ ] Envoy Gateway deployed and healthy on <cluster>
- [ ] ClientTrafficPolicy with `withUnderscoresAction: Allow` applied
- [ ] EnvoyProxy access log includes `%RESPONSE_CODE_DETAILS%`
- [ ] cert-manager configured with `config.enableGatewayAPI: true`
- [ ] Gateway ClusterIssuer for http01 gatewayHTTPRoute solver exists

## Step 1: Helm Chart Template Changes

### File: <chart-path>/templates/httproute.yaml
Action: [Create / Already exists / Not needed (system app)]
Content:
  [Exact template content, gated on gatewayAPI.enabled]
  [For library charts: also gate on role == web]

### File: <chart-path>/templates/backendtrafficpolicy.yaml
Action: [Create / Not needed / Already exists]
Content:
  [Exact template content if needed]

### File: <chart-path>/values.yaml
Action: [Add gatewayAPI defaults / Already has them]
Diff:
  [Show exact diff -- gatewayAPI.enabled: false as default]

### Lint and Validate
Commands:
  helm lint <chart-path> -f <chart-path>/values.yaml -f <chart-path>/<env>-values.yaml
  helm template <release> <chart-path> -f ... --set gatewayAPI.enabled=true | grep "kind:" | sort | uniq -c
  helm template <release> <chart-path> -f ... | kubeconform -strict -ignore-missing-schemas -summary

## Step 2: Enable Gateway API in Environment Values

### File: <chart-path>/<env>-values.yaml
Diff:
  +gatewayAPI:
  +  enabled: true
  +  [requestBufferLimit: "XXMi"]
  +  [timeout:]
  +  [  http:]
  +  [    requestTimeout: "XXXs"]
  +  [sessionAffinity:]
  +  [  cookieName: "xxx"]
  +  [  cookieTTL: "XXXs"]

[If library chart override needed:]
### File: <chart-path>/<web-env-override>-values.yaml
Action: Create
Content:
  ingress:
    enabled: false

## Step 3: Add Gateway Listener

### File: <infrastructure-repo-path>/<gateway-config-file>
Action: Add HTTPS listener for this hostname
Diff:
  +  - name: https-<short-name>
  +    protocol: HTTPS
  +    port: 443
  +    hostname: "<hostname>"
  +    allowedRoutes:
  +      namespaces:
  +        from: All
  +    tls:
  +      mode: Terminate
  +      certificateRefs:
  +      - kind: Secret
  +        name: <tls-secret-name>

## Step 4: Copy TLS Secret (before DNS cutover)

Copy the existing TLS secret to the Envoy Gateway namespace so TLS works
before cert-manager can issue a new certificate via the Gateway:

Command:
  kubectl get secret <tls-secret-name> -n <namespace> -o json | \
    jq '.metadata = {name: .metadata.name, namespace: "<envoy-gateway-namespace>"}' | \
    kubectl apply -f -

## Step 5: Pre-Cutover Validation (direct IP test)

Test the app through Envoy's LoadBalancer IP before switching DNS:

Commands:
  ENVOY_IP=$(kubectl get svc -n <envoy-gateway-namespace> \
    -l gateway.envoyproxy.io/owning-gateway-name=<gateway-name> \
    -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}')
  curl -sv --resolve "<hostname>:443:${ENVOY_IP}" "https://<hostname>/"

Expected: HTTP 200 (or app-appropriate response), valid TLS, server: envoy
[If BTP: verify timeout behavior, cookie headers, body size limits]
[If auth: verify login flow works end-to-end]

## Step 6: Atomic DNS Cutover

Disable nginx Ingress and enable Envoy HTTPRoute in a SINGLE commit/deploy.

### File: <chart-path>/<env>-values.yaml
Diff:
   ingress:
  -  enabled: true
  +  enabled: false
     hosts:
       - host: <hostname>   # KEEP -- HTTPRoute template may read this

CRITICAL: ingress.enabled: false and gatewayAPI.enabled: true must take
effect simultaneously. For GitOps, this means a single commit. For CI/CD,
ensure both changes deploy in the same pipeline run.

[Steps 2 and 6 can be combined into a single commit for atomic cutover,
OR kept as separate commits if you want to validate via direct IP first
(Step 5) before switching DNS.]

## Step 7: Post-Cutover Validation

Commands:
  # Verify via public DNS
  curl -sv "https://<hostname>/"

  # Verify HTTPRoute is accepted
  kubectl get httproute -n <namespace>

  # Verify Ingress is gone
  kubectl get ingress -n <namespace>

  # Verify DNS resolves (may take a few minutes for propagation)
  dig +short <hostname>

  # Check Envoy access logs for errors
  kubectl logs -n <envoy-gateway-namespace> -l gateway.envoyproxy.io/owning-gateway-name=<gateway-name> --tail=50

[If observability available: compare error rates with pre-migration baseline]

## Step 8: Post-Migration Cleanup and Tracking

- Update migration tracking (README or status document) for this cluster
- Clean up any orphaned resources:
  - Stale DNS records if external-dns policy is upsert-only
  - Old TLS secret copies if no longer needed
  - Orphaned Helm release secrets if deployment method changed

[If DR cluster exists for this hostname:]
## DR Cluster Values Update

This hostname (<hostname>) also exists on DR cluster <dr-cluster> (hibernated).
After successful migration on the primary, update the DR cluster's values file:

### File: <chart-path>/<dr-env>-values.yaml
Diff:
  +gatewayAPI:
  +  enabled: true
   ingress:
  -  enabled: true
  +  enabled: false

This ensures the DR cluster uses Envoy Gateway if activated during failover.
NOTE: The DR cluster must also have Envoy Gateway infrastructure deployed
(`/setup-cluster`) before it can actually serve traffic via HTTPRoute.

## Rollback Procedure

If something goes wrong after cutover:

1. Re-enable nginx Ingress:
   - Set `ingress.enabled: true` in <env>-values.yaml
   - Set `gatewayAPI.enabled: false` (or remove the key)
   - Deploy/sync the change

2. Verify nginx is serving traffic:
   - `curl -sv "https://<hostname>/"`
   - Check that DNS resolves to the nginx LB IP

3. If nginx was already scaled down:
   - Scale nginx controller back up
   - If HPA exists, re-enable `autoscaling.enabled: true` first
```

## Common Mistakes to Avoid

These are verified failure modes from real migrations:

1. **Using `targetRef` (singular) instead of `targetRefs` (plural list)** -- deprecated in Envoy Gateway v1.7.0. Use the plural form.
2. **Using `spec.sessionPersistence` on BackendTrafficPolicy** -- this field does NOT exist. Use `spec.loadBalancer.consistentHash.cookie.{name, ttl}` instead.
3. **Using `requestBuffer.limit: 10m`** -- wrong unit. `10m` means 10 millicores in Kubernetes resource.Quantity. Use `10Mi` for 10 mebibytes.
4. **Using SecurityPolicy extAuth with oauth2-proxy** -- Envoy strips Location headers from ext_authz responses, breaking browser login redirects. Use the reverse proxy pattern instead.
5. **Using `featureGates` for cert-manager Gateway API support** -- deprecated. Use `config.enableGatewayAPI: true` in cert-manager Helm values. Also requires a pod restart after RBAC update.
6. **Setting `gatewayAPI.enabled: true` in root `values.yaml`** -- affects ALL clusters/environments immediately. Only set this in environment-specific values files.
7. **Forgetting `allowedRoutes.namespaces.from: All` on Gateway listener** -- default is `from: Same`, which rejects HTTPRoutes from app namespaces. The HTTPRoute will show `Accepted: False`.
8. **Not copying the TLS secret before DNS cutover** -- cert-manager http01 challenges cannot reach Envoy while DNS still points to nginx. Copy the existing secret to the Envoy Gateway namespace first.
9. **Having both Ingress AND HTTPRoute active for the same hostname** -- external-dns will flap the DNS A record between the nginx and Envoy LoadBalancer IPs, causing intermittent failures.
10. **Forgetting the web-values override for library chart apps** -- if a role-based values file (e.g., `web-values.yaml`) loads after the env-specific file, it can re-enable `ingress.enabled: true`. Add an override file loaded last.
