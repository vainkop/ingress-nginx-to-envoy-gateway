---
name: generate-httproute
description: >
  Generates ready-to-apply HTTPRoute and policy YAML from an existing ingress-nginx Ingress.
  Produces all required Gateway API resources with REPLACE comments for customization.
  Use when "generate httproute for X", "convert ingress for X", "create httproute yaml",
  "produce envoy config for X".
license: Apache-2.0
metadata:
  author: vainkop
  version: 1.0.0
  tags: [generation, httproute, yaml, conversion]
---

# Generate HTTPRoute and Policy YAML from Ingress

This skill takes an existing ingress-nginx Ingress resource (live or from file), extracts
all routing configuration, and produces ready-to-apply Gateway API YAML for HTTPRoute,
BackendTrafficPolicy, SecurityPolicy, and Gateway listener additions.

## Prerequisites

- `kubectl` access to the cluster (for live Ingress), OR an Ingress YAML file
- `migration.config.yaml` populated for Gateway name, namespace, and TLS issuer

## Procedure

### Step 1: Get the Source Ingress

**From a live cluster:**

```bash
kubectl get ingress <name> -n <namespace> -o yaml
```

**From a file:**

Read the provided YAML file directly.

If neither is provided, ask the user for:
- App name
- Namespace
- Cluster (to determine kubectl context from `config.clusters[]`)

### Step 2: Extract Configuration

Parse the Ingress and extract:

| Field | Source | Example |
|-------|--------|---------|
| Hostname(s) | `spec.rules[].host` | `app.example.com` |
| Path(s) | `spec.rules[].http.paths[]` | `/`, `/api/*` |
| Path type(s) | `spec.rules[].http.paths[].pathType` | `Prefix`, `ImplementationSpecific` |
| Backend service | `spec.rules[].http.paths[].backend.service.name` | `my-app` |
| Backend port | `spec.rules[].http.paths[].backend.service.port.number` | `8080` |
| TLS hosts | `spec.tls[].hosts` | `[app.example.com]` |
| TLS Secret | `spec.tls[].secretName` | `app-tls` |
| Ingress class | `spec.ingressClassName` or annotation | `nginx` |
| All annotations | `metadata.annotations` | See annotation mapping |

### Step 3: Generate HTTPRoute YAML

Map path types: `Prefix` stays `PathPrefix`, `ImplementationSpecific` becomes `PathPrefix`
(nginx treats `ImplementationSpecific` as prefix by default), `Exact` stays `Exact`.

```yaml
# REPLACE: Update parentRefs to match your Gateway
# REPLACE: Verify hostname matches your DNS configuration
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: <ingress-name>  # REPLACE: if you want a different name
  namespace: <namespace>
  labels:
    app.kubernetes.io/name: <app-name>
    app.kubernetes.io/managed-by: envoy-gateway-migration
spec:
  parentRefs:
    - name: <gateway-name>  # REPLACE: from config.advanced or your Gateway name
      namespace: <gateway-namespace>  # REPLACE: from config.advanced.namespace
      sectionName: <listener-name>  # REPLACE: match your Gateway HTTPS listener
  hostnames:
    - <hostname>  # From spec.rules[].host
  rules:
    # One rule per path from the Ingress
    - matches:
        - path:
            type: PathPrefix  # Mapped from Ingress pathType
            value: <path>     # From spec.rules[].http.paths[].path
      backendRefs:
        - name: <service-name>  # From backend.service.name
          port: <port>          # From backend.service.port.number
```

**For multiple paths**, generate one rule per path.

**For regex rewrites** (`rewrite-target` annotation with capture groups):

```yaml
  rules:
    - matches:
        - path:
            type: RegularExpression
            value: <regex-pattern>  # Converted from nginx regex to RE2
      filters:
        - type: URLRewrite
          urlRewrite:
            path:
              type: RegexHTTPPathModifier
              regexHTTPPathModifier:
                pattern: <match-pattern>
                substitution: <replacement>
      backendRefs:
        - name: <service-name>
          port: <port>
```

**For SSL redirect** (`ssl-redirect: "true"` annotation), generate an HTTP-to-HTTPS redirect rule
or note that this is typically handled at the Gateway listener level.

### Step 4: Generate BackendTrafficPolicy (If Needed)

Only generate if the Ingress has timeout, body size, CORS, rate limit, or session affinity annotations.

```yaml
# REPLACE: Ensure the targetRef name matches your HTTPRoute
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: BackendTrafficPolicy
metadata:
  name: <ingress-name>-btp
  namespace: <namespace>
  labels:
    app.kubernetes.io/name: <app-name>
    app.kubernetes.io/managed-by: envoy-gateway-migration
spec:
  targetRefs:  # NOTE: Use plural targetRefs, not deprecated singular targetRef
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: <httproute-name>
```

Add fields based on detected annotations:

**Timeout** (from `proxy-read-timeout`, `proxy-send-timeout`):
```yaml
  timeout:
    http:
      requestTimeout: "<timeout-value>s"  # Convert nginx seconds to duration string
```

**Request body limit** (from `proxy-body-size`):
```yaml
  # NOTE: This is on BackendTrafficPolicy, NOT ClientTrafficPolicy
  # CTP.spec.clientRequestBody does NOT exist in Envoy Gateway v1.7.0
  requestBuffer:
    limit: "<size>"  # resource.Quantity, e.g., "10Mi", "100Ki"
```

**Session affinity** (from `affinity: cookie`, `session-cookie-name`):
```yaml
  # NOTE: Use loadBalancer.consistentHash.cookie
  # BTP.spec.sessionPersistence does NOT exist in Envoy Gateway v1.7.0
  loadBalancer:
    type: ConsistentHash
    consistentHash:
      type: Cookie
      cookie:
        name: "<cookie-name>"  # From session-cookie-name annotation
        ttl: "<max-age>s"      # From session-cookie-max-age annotation
        attributes:
          sameSite: Strict
```

**CORS** (from `cors-*` annotations):
```yaml
  cors:
    allowOrigins:
      - type: Exact  # or RegularExpression
        value: "<origin>"  # From cors-allow-origin
    allowMethods:
      - "<method>"  # From cors-allow-methods (split on comma)
    allowHeaders:
      - "<header>"  # From cors-allow-headers (split on comma)
    exposeHeaders:
      - "<header>"  # From cors-expose-headers (split on comma)
    allowCredentials: <bool>  # From cors-allow-credentials
    maxAge: "<duration>"  # From cors-max-age
```

### Step 5: Generate SecurityPolicy (If Needed)

**For basic auth** (`auth-type: basic`):

```yaml
# REPLACE: Create the htpasswd Secret first (see instructions below)
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: SecurityPolicy
metadata:
  name: <ingress-name>-basic-auth
  namespace: <namespace>
  labels:
    app.kubernetes.io/name: <app-name>
    app.kubernetes.io/managed-by: envoy-gateway-migration
spec:
  targetRefs:  # NOTE: Use plural targetRefs, not deprecated singular targetRef
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: <httproute-name>
  basicAuth:
    users:
      name: <secret-name>  # Must contain .htpasswd key with SHA hash (NOT bcrypt)
```

Include instructions for creating the Secret:

```bash
# Generate htpasswd with SHA hash (Envoy does NOT support bcrypt)
htpasswd -s -c auth-file <username>

# Create the Kubernetes Secret
kubectl create secret generic <secret-name> \
  --from-file=.htpasswd=auth-file \
  -n <namespace>
```

**For oauth2-proxy** (`auth-url` + `auth-signin` annotations):

Do NOT generate a SecurityPolicy. Instead, output a WARNING:

```
# WARNING: oauth2-proxy detected (auth-url/auth-signin annotations present)
#
# DO NOT use SecurityPolicy extAuth with oauth2-proxy.
# Envoy strips Location headers from auth subrequest responses,
# which completely breaks browser login redirects.
#
# CORRECT PATTERN: Route traffic through oauth2-proxy as a reverse proxy.
# 1. Configure oauth2-proxy with OAUTH2_PROXY_UPSTREAMS=http://<app-service>.<namespace>.svc:port/
# 2. Create HTTPRoute pointing to oauth2-proxy service (not the app service)
# 3. Create a separate HTTPRoute for /oauth2/* paths
#
# See docs/auth-migration-patterns.md for complete examples.
```

Then generate the reverse proxy HTTPRoute pattern:

```yaml
# HTTPRoute for the main app traffic (through oauth2-proxy)
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: <app-name>
  namespace: <namespace>
spec:
  parentRefs:
    - name: <gateway-name>
      namespace: <gateway-namespace>
      sectionName: <listener-name>
  hostnames:
    - <hostname>
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: <oauth2-proxy-service>  # REPLACE: oauth2-proxy service name
          port: 4180  # REPLACE: oauth2-proxy port
---
# HTTPRoute for oauth2-proxy callback paths
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: <app-name>-oauth2
  namespace: <oauth2-proxy-namespace>  # REPLACE: namespace where oauth2-proxy runs
spec:
  parentRefs:
    - name: <gateway-name>
      namespace: <gateway-namespace>
      sectionName: <listener-name>
  hostnames:
    - <hostname>
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /oauth2
      backendRefs:
        - name: <oauth2-proxy-service>  # REPLACE: oauth2-proxy service name
          port: 4180  # REPLACE: oauth2-proxy port
```

### Step 6: Generate Gateway Listener Snippet

If the app's hostname does not already have a Gateway listener, generate one:

```yaml
# Add this listener to your existing Gateway resource
# REPLACE: Ensure the TLS secret exists in the Gateway namespace
- name: <app-name>-https  # Unique listener name
  protocol: HTTPS
  port: 443
  hostname: <hostname>
  allowedRoutes:
    namespaces:
      from: All  # CRITICAL: Must be All, not Same
  tls:
    mode: Terminate
    certificateRefs:
      - kind: Secret
        name: <tls-secret-name>  # REPLACE: TLS secret in Gateway namespace
        namespace: <gateway-namespace>
```

Also remind the user about the TLS chicken-and-egg:

```bash
# Copy existing TLS secret to Gateway namespace (before DNS cutover)
kubectl get secret <tls-secret-name> -n <app-namespace> -o yaml | \
  sed 's/namespace: .*/namespace: <gateway-namespace>/' | \
  kubectl apply -f -
```

### Step 7: Validate Generated YAML

If `kubectl` access is available, dry-run the generated resources:

```bash
# Validate HTTPRoute
kubectl apply --dry-run=client -f httproute.yaml

# Validate BackendTrafficPolicy (if generated)
kubectl apply --dry-run=client -f backendtrafficpolicy.yaml

# Validate SecurityPolicy (if generated)
kubectl apply --dry-run=client -f securitypolicy.yaml
```

Report any validation errors.

### Step 8: Output All YAML

Present all generated YAML in order of application:

1. **Gateway listener snippet** (to be merged into existing Gateway)
2. **TLS Secret copy command** (run before DNS cutover)
3. **HTTPRoute** (core routing)
4. **BackendTrafficPolicy** (if needed)
5. **SecurityPolicy** (if needed, basic auth only)

Each YAML block should include:
- `# REPLACE:` comments on every field that needs user customization
- `# NOTE:` comments on fields that differ from nginx behavior
- `# WARNING:` comments on known gotchas

## Output Format

```
=== Generated Gateway API Resources for <app-name> ===

Source: Ingress/<name> in namespace <namespace>
Complexity: <Simple|Medium|Complex|Critical>
Resources generated: <count>

--- 1. Gateway Listener Addition ---
<yaml>

--- 2. TLS Secret Copy ---
<command>

--- 3. HTTPRoute ---
<yaml>

--- 4. BackendTrafficPolicy ---
<yaml or "Not needed">

--- 5. SecurityPolicy ---
<yaml or "Not needed" or "WARNING: oauth2-proxy detected">

--- Validation ---
<dry-run results or "Run kubectl apply --dry-run=client to validate">

--- Next Steps ---
1. Review all REPLACE comments and update values
2. Apply Gateway listener update
3. Copy TLS secret to Gateway namespace
4. Apply HTTPRoute (and policies)
5. Test via direct IP: curl --resolve <hostname>:443:<envoy-lb-ip> https://<hostname>/
6. Perform atomic DNS cutover (ingress.enabled=false + gatewayAPI.enabled=true)
```

## References

- `examples/httproute/` -- Reference YAML for all complexity levels
- `examples/gateway/` -- Gateway and listener examples
- `docs/envoy-gateway-v1.7-crd-reference.md` -- CRD field reference
- `docs/auth-migration-patterns.md` -- oauth2-proxy reverse proxy pattern
- `docs/gotchas.md` -- Known pitfalls
- CLAUDE.md constraints: 5, 7, 8, 13, 14, 16, 17
