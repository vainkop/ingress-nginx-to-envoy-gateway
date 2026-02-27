---
name: migrate-app
description: >
  Migrates a single application from ingress-nginx Ingress to Envoy Gateway HTTPRoute.
  Handles all complexity levels: simple routing, BackendTrafficPolicy, auth-protected,
  and system/upstream apps. Use when "migrate X", "move X to envoy", "switch X to gateway api".
license: Apache-2.0
metadata:
  author: vainkop
  version: 1.0.0
  tags: [migration, httproute, per-app]
---

# Migrate a Single App from Ingress to HTTPRoute

This skill provides the complete step-by-step workflow for migrating one application from
ingress-nginx to Envoy Gateway. It covers chart modifications, template creation, testing,
and atomic DNS cutover.

## Prerequisites

- `migration.config.yaml` populated for the target cluster
- Cluster setup complete (run `/setup-cluster` or `/pre-flight-check` first)
- App name and namespace known
- Access to the Helm chart (in `config.repos.helm_charts`, `config.repos.standalone_apps[]`,
  or the app's own repo)

## Procedure

### Step 1: Gather App Information

Collect the following for the target app:

1. **Current Ingress YAML**: `kubectl get ingress <name> -n <namespace> -o yaml`
2. **Helm chart location**: Is it in the shared charts repo, a standalone app repo, or a library chart?
3. **Values files**: Which environment-specific values files apply to this cluster?
4. **Ingress annotations**: List all `nginx.ingress.kubernetes.io/*` annotations
5. **TLS configuration**: Certificate Secret name, issuer annotation
6. **Backend services**: Service name, port, protocol
7. **Auth configuration**: Is oauth2-proxy or basic auth in front of this app?

Record the current Ingress hostname and the nginx LoadBalancer IP for rollback reference.

### Step 2: Classify Migration Complexity

Based on the annotations and configuration gathered, classify the app:

| Complexity | Criteria | Resources Needed |
|------------|----------|-----------------|
| **Simple** | Host + path routing only, maybe TLS. No special annotations. | HTTPRoute |
| **BTP** | Has timeout, body size, CORS, rate limit, or session affinity annotations. | HTTPRoute + BackendTrafficPolicy |
| **Auth (basic)** | Uses HTTP basic auth (htpasswd). | HTTPRoute + SecurityPolicy (basicAuth) |
| **Auth (oauth2-proxy)** | Uses oauth2-proxy for authentication. | HTTPRoute for app + HTTPRoute for oauth2-proxy (reverse proxy pattern) |
| **System** | Upstream chart (not your Helm chart). Cannot add templates. | Standalone HTTPRoute YAML in GitOps repo |

**Annotation-to-resource mapping reference:**

| nginx Annotation | Envoy Resource | Field |
|-----------------|----------------|-------|
| `proxy-read-timeout` / `proxy-send-timeout` | BackendTrafficPolicy | `spec.timeout.http.requestTimeout` |
| `proxy-body-size` | BackendTrafficPolicy | `spec.requestBuffer.limit` |
| `affinity: cookie` | BackendTrafficPolicy | `spec.loadBalancer.consistentHash.cookie` |
| `cors-*` | BackendTrafficPolicy | `spec.cors` |
| `limit-rps` | BackendTrafficPolicy | `spec.rateLimit` |
| `proxy-buffering` | BackendTrafficPolicy | `spec.responseOverride` (limited) |
| `auth-type: basic` | SecurityPolicy | `spec.basicAuth` |
| `auth-url` + `auth-signin` (oauth2-proxy) | **DO NOT use SecurityPolicy extAuth** | Use reverse proxy pattern instead |
| `websocket` | HTTPRoute | Works by default (no annotation needed) |
| `ssl-redirect` | HTTPRoute | `requestRedirect` filter |
| `rewrite-target` | HTTPRoute | `urlRewrite` filter |

### Step 3: Add HTTPRoute Template to Chart

**For standalone charts** (chart has its own `templates/ingress.yaml`):

Create `templates/httproute.yaml` gated on `gatewayAPI.enabled`:

```yaml
{{- if .Values.gatewayAPI.enabled }}
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: {{ include "<chart>.fullname" . }}
  labels:
    {{- include "<chart>.labels" . | nindent 4 }}
spec:
  parentRefs:
    - name: {{ .Values.gatewayAPI.gateway.name }}
      namespace: {{ .Values.gatewayAPI.gateway.namespace }}
      sectionName: {{ .Values.gatewayAPI.gateway.sectionName }}
  hostnames:
    - {{ .Values.gatewayAPI.hostname }}
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: {{ include "<chart>.fullname" . }}
          port: {{ .Values.service.port }}
{{- end }}
```

If a BackendTrafficPolicy is needed, create `templates/backendtrafficpolicy.yaml` similarly.

**For library charts** (shared template included via `{{ include "library.httproute" . }}`):

Add the include to the app's `templates/library.yaml` and rebuild dependencies:

```bash
helm dependency update <chart-path>
```

Gate on BOTH `role: web` AND `gatewayAPI.enabled` to avoid rendering for non-web components.

**For system/upstream apps** (cannot modify the chart):

Create a standalone HTTPRoute YAML file in `config.repos.infrastructure` following
existing patterns for the GitOps tool (Flux Kustomization or ArgoCD Application).

### Step 4: Add gatewayAPI Defaults to values.yaml

Add to the chart's **root** `values.yaml` (disabled by default):

```yaml
gatewayAPI:
  enabled: false
  hostname: ""
  gateway:
    name: ""
    namespace: "envoy-gateway-system"
    sectionName: "https"
  tls:
    issuerName: ""
    issuerKind: "ClusterIssuer"
```

**NEVER set `enabled: true` in root values.yaml.** Only enable in env-specific values files.

### Step 5: Lint and Validate Templates

Run these checks before committing:

```bash
# Lint the chart
helm lint <chart-path> -f <env-values-file>

# Render templates and inspect output
helm template <release-name> <chart-path> \
  -f <env-values-file> \
  --set gatewayAPI.enabled=true \
  --set gatewayAPI.hostname=app.example.com

# Validate against Gateway API CRDs (if kubeconform is available)
helm template <release-name> <chart-path> -f <env-values-file> | \
  kubeconform -strict -schema-location default \
  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceVersion}}.json'
```

### Step 6: Add Gateway Listener for the Hostname

Add a new HTTPS listener to the cluster's Gateway for this app's hostname:

```yaml
listeners:
  - name: <app-name>-https
    protocol: HTTPS
    port: 443
    hostname: <app-hostname>
    allowedRoutes:
      namespaces:
        from: All
    tls:
      mode: Terminate
      certificateRefs:
        - kind: Secret
          name: <tls-secret-name>
          namespace: <config.advanced.namespace>
```

Apply the updated Gateway.

### Step 7: Copy TLS Secret to Gateway Namespace

Before DNS cutover, cert-manager http01 challenges cannot reach Envoy (DNS still points
to nginx). Copy the existing TLS Secret as a workaround:

```bash
kubectl get secret <tls-secret-name> -n <app-namespace> -o yaml | \
  sed 's/namespace: .*/namespace: <config.advanced.namespace>/' | \
  kubectl apply -f -
```

After DNS switches to Envoy, cert-manager will auto-renew through the new path.

### Step 8: Enable gatewayAPI and Validate via Direct IP

In the env-specific values file for this cluster, set:

```yaml
gatewayAPI:
  enabled: true
  hostname: <app-hostname>
  gateway:
    name: <gateway-name>
    namespace: <config.advanced.namespace>
    sectionName: <listener-name>
```

Deploy the change. This creates the HTTPRoute but DNS still points to nginx, so no
user-facing impact yet.

**Validate by curling the Envoy LB IP directly:**

```bash
curl -v --resolve <hostname>:443:<envoy-lb-ip> https://<hostname>/
```

Confirm you get the expected response. Check for:
- Correct HTTP status code
- No `server: nginx` header (should be `server: envoy` or absent)
- TLS certificate is valid

### Step 9: Atomic DNS Cutover

**This is the critical step.** In a SINGLE commit/deploy, set:

```yaml
ingress:
  enabled: false
gatewayAPI:
  enabled: true
```

**NEVER have both Ingress and HTTPRoute active for the same hostname.**
This causes external-dns to flap the DNS A record between the nginx and Envoy LB IPs.

If `config.dns.external_dns_policy` is `upsert-only`, manually verify the DNS record
updated to the Envoy LB IP. If the old record persists, manually update/delete it in
your DNS provider.

After cutover, verify:
1. DNS resolves to the Envoy LB IP
2. The application responds correctly through the new path
3. No errors in Envoy access logs (`kubectl logs` on the Envoy proxy pod)

### Step 10: Update Migration Tracking

Update the migration status tracking (README.md or tracking document) to reflect
the completed migration. Record:
- App name and namespace
- Migration date
- Complexity classification
- Any issues encountered

## Auth App Migration (Special Handling)

### oauth2-proxy Pattern (CRITICAL)

**DO NOT use SecurityPolicy extAuth with oauth2-proxy.** Envoy strips `Location` headers
from auth subrequest responses, which completely breaks browser login redirects.

**Correct pattern -- reverse proxy:**

1. Configure oauth2-proxy with `OAUTH2_PROXY_UPSTREAMS` pointing to the app's service
2. Create an HTTPRoute for oauth2-proxy handling the app's hostname (all paths)
3. Create a separate HTTPRoute for `/oauth2/*` paths pointing to oauth2-proxy's service
4. Traffic flow: User -> Envoy -> oauth2-proxy -> app service (internal)

Both HTTPRoutes must be migrated together in the same cutover.

### Basic Auth Pattern

SecurityPolicy with basicAuth works correctly. Create a Secret with a `.htpasswd` key:

```bash
# Generate with SHA hash (not bcrypt -- Envoy does not support bcrypt)
htpasswd -s -c auth-file username
kubectl create secret generic <secret-name> --from-file=.htpasswd=auth-file -n <namespace>
```

```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: SecurityPolicy
metadata:
  name: <app-name>-basic-auth
  namespace: <namespace>
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: <httproute-name>
  basicAuth:
    users:
      name: <secret-name>
```

## CRD Field Reference (Envoy Gateway v1.7.0)

| What You Want | Wrong Field | Correct Field |
|--------------|-------------|---------------|
| Session affinity | `BTP.spec.sessionPersistence` (does not exist) | `BTP.spec.loadBalancer.consistentHash.cookie` |
| Request body limit | `CTP.spec.clientRequestBody` (does not exist) | `BTP.spec.requestBuffer.limit` (resource.Quantity) |
| Singular target ref | `spec.targetRef` (deprecated) | `spec.targetRefs` (plural list) |

## Rollback Procedure

If issues are found after cutover:

1. Re-enable the Ingress: set `ingress.enabled: true` and `gatewayAPI.enabled: false`
2. If DNS was using `upsert-only` policy, verify the A record flipped back to the nginx LB IP
3. If it did not, manually update DNS to the nginx LB IP
4. Delete the HTTPRoute: `kubectl delete httproute <name> -n <namespace>`

## Common Issues

- **HTTPRoute not accepted**: Check Gateway listener exists for the hostname, `allowedRoutes` is `from: All`
- **TLS errors**: Secret not copied to Gateway namespace, or cert-manager issuer not ready
- **400 errors after cutover**: Missing ClientTrafficPolicy for underscore headers
- **DNS flapping**: Both Ingress and HTTPRoute active simultaneously -- disable one immediately
- **oauth2-proxy login broken**: Used SecurityPolicy extAuth instead of reverse proxy pattern

## References

- `docs/gotchas.md` -- Battle-tested gotchas
- `docs/auth-migration-patterns.md` -- Detailed auth patterns
- `docs/dns-cutover-strategy.md` -- DNS cutover details
- `docs/helm-template-strategy.md` -- Chart template strategy
- `docs/envoy-gateway-v1.7-crd-reference.md` -- CRD field reference
- `examples/httproute/` -- Ready-to-use HTTPRoute templates
- `examples/helm-values/` -- Example values files
- CLAUDE.md constraints: 5, 6, 7, 8, 12, 13, 16, 17, 19, 20, 21
