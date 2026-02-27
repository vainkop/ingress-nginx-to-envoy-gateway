# Annotation Mapping: ingress-nginx to Envoy Gateway

Complete mapping of ingress-nginx annotations to their Envoy Gateway (v1.7.0) equivalents.

## Direct Mappings

### proxy-body-size
```yaml
# nginx annotation
nginx.ingress.kubernetes.io/proxy-body-size: "512m"

# Envoy Gateway v1.7.0 equivalent: BackendTrafficPolicy requestBuffer
# NOTE: This buffers the entire request body before forwarding (unlike nginx which streams).
# Use Kubernetes resource.Quantity format: "512Mi", "10Mi" (NOT "512m", "10m").
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: BackendTrafficPolicy
metadata:
  name: <app-name>-btp
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: <app-name>
  requestBuffer:
    limit: 512Mi
```

### proxy-read-timeout / proxy-send-timeout
```yaml
# nginx annotations
nginx.ingress.kubernetes.io/proxy-read-timeout: "3600"
nginx.ingress.kubernetes.io/proxy-send-timeout: "3600"

# Envoy Gateway v1.7.0 equivalent (Envoy unifies into requestTimeout)
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: BackendTrafficPolicy
metadata:
  name: <app-name>-btp
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: <app-name>
  timeout:
    http:
      requestTimeout: "3600s"
```

### proxy-connect-timeout
```yaml
# nginx annotation
nginx.ingress.kubernetes.io/proxy-connect-timeout: "60"

# Envoy Gateway equivalent
spec:
  timeout:
    tcp:
      connectTimeout: "60s"
```

### websocket-services
```yaml
# nginx annotation
nginx.ingress.kubernetes.io/websocket-services: "my-websocket-app"

# Envoy Gateway: NO ANNOTATION NEEDED
# Envoy natively supports WebSocket upgrade (HTTP/1.1 Upgrade: websocket).
# Just ensure timeouts are long enough via BackendTrafficPolicy so
# idle WebSocket connections are not closed prematurely.
```

### affinity: cookie (session persistence)
```yaml
# nginx annotations
nginx.ingress.kubernetes.io/affinity: "cookie"
nginx.ingress.kubernetes.io/affinity-mode: "persistent"
nginx.ingress.kubernetes.io/session-cookie-name: "my_route"
nginx.ingress.kubernetes.io/session-cookie-max-age: "3600"

# Envoy Gateway v1.7.0 equivalent: ConsistentHash cookie load balancing
# CRITICAL: v1.7.0 has NO spec.sessionPersistence field.
# Use loadBalancer.consistentHash.cookie instead.
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: BackendTrafficPolicy
metadata:
  name: <app-name>-btp
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: <app-name>
  loadBalancer:
    type: ConsistentHash
    consistentHash:
      type: Cookie
      cookie:
        name: "my_route"
        ttl: "3600s"
```

### kubernetes.io/tls-acme
```yaml
# nginx: annotation on Ingress resource
kubernetes.io/tls-acme: "true"

# Envoy Gateway: annotation on Gateway resource (NOT on HTTPRoute)
# The Gateway must have a cert-manager annotation and a TLS listener:
metadata:
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod-gateway
spec:
  listeners:
  - name: https-my-app
    protocol: HTTPS
    port: 443
    hostname: "my-app.example.com"
    tls:
      mode: Terminate
      certificateRefs:
      - kind: Secret
        name: my-app.example.com-tls
```

## Auth Annotations

### auth-url + auth-signin (External Auth / oauth2-proxy)
```yaml
# nginx annotations (on the protected app's Ingress)
nginx.ingress.kubernetes.io/auth-url: "https://$host/oauth2/auth"
nginx.ingress.kubernetes.io/auth-signin: "https://$host/oauth2/start?rd=$escaped_request_uri"

# Envoy Gateway v1.7.0: DO NOT use SecurityPolicy extAuth!
# Envoy strips Location headers from auth responses, breaking browser redirects.
#
# Instead: Route ALL traffic through oauth2-proxy as a reverse proxy.
# oauth2-proxy handles auth and forwards to the app via OAUTH2_PROXY_UPSTREAMS.
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: <app-name>
spec:
  parentRefs:
  - name: envoy-gateway
    namespace: envoy-gateway-system
  hostnames:
  - "my-app.example.com"
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /
    backendRefs:
    - name: oauth2-proxy       # Route to oauth2-proxy, NOT to the app directly
      port: 4180
```

**CRITICAL WARNING**: SecurityPolicy extAuth does NOT work with oauth2-proxy because:
- Envoy's ext_authz filter strips `Location` headers from auth service responses
- Without the Location header, the browser shows raw HTML instead of redirecting to the login page
- This is a fundamental incompatibility with the nginx `auth-url`/`auth-signin` pattern

The correct pattern is to route traffic through oauth2-proxy as a reverse proxy:
- Configure `OAUTH2_PROXY_UPSTREAMS: "http://<app-service>.<namespace>.svc.cluster.local"` on the oauth2-proxy
- oauth2-proxy handles the full auth flow (redirect to OIDC login, callback, cookie management)
- Authenticated requests are forwarded to the upstream app

### auth-response-headers
```yaml
# nginx annotation
nginx.ingress.kubernetes.io/auth-response-headers: "Authorization"

# Envoy Gateway equivalent: part of SecurityPolicy extAuth
# NOTE: Only relevant if using extAuth for non-oauth2-proxy scenarios
spec:
  extAuth:
    http:
      headersToBackend:
      - Authorization
```

### auth-type: basic + auth-secret (HTTP Basic Auth)
```yaml
# nginx annotations
nginx.ingress.kubernetes.io/auth-type: basic
nginx.ingress.kubernetes.io/auth-secret: my-basic-auth
nginx.ingress.kubernetes.io/auth-realm: "My Realm"

# Envoy Gateway v1.7.0: SecurityPolicy with basicAuth
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: SecurityPolicy
metadata:
  name: <app-name>-basic-auth
spec:
  targetRefs:
  - group: gateway.networking.k8s.io
    kind: HTTPRoute
    name: <app-name>
  basicAuth:
    users:
      name: <secret-name>    # Opaque Secret with key ".htpasswd"
```

IMPORTANT notes on basicAuth:
- Secret MUST have key `.htpasswd` (not `auth` or other key names)
- Only SHA hash algorithm is supported (not bcrypt like nginx)
- Generate with: `htpasswd -s -n <username>` or `htpasswd -sbc .htpasswd <username> <password>`
- Secret must be in the same namespace as the SecurityPolicy
- Use `targetRefs` (plural list), NOT the deprecated singular `targetRef`

### backend-protocol: HTTPS
```yaml
# nginx annotation
nginx.ingress.kubernetes.io/backend-protocol: "HTTPS"

# Envoy Gateway equivalent: BackendTLSPolicy
apiVersion: gateway.networking.k8s.io/v1alpha3
kind: BackendTLSPolicy
metadata:
  name: <app-name>-backend-tls
spec:
  targetRefs:
  - group: ""
    kind: Service
    name: <backend-service>
  validation:
    caCertificateRefs: []        # Empty = skip CA validation
    hostname: <backend-hostname>
    wellKnownCACertificates: "System"
```

### large-client-header-buffers
```yaml
# nginx annotation
nginx.ingress.kubernetes.io/large-client-header-buffers: "4 16k"

# Envoy Gateway equivalent: ClientTrafficPolicy
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: ClientTrafficPolicy
metadata:
  name: <app-name>-ctp
spec:
  targetRefs:
  - group: gateway.networking.k8s.io
    kind: Gateway
    name: envoy-gateway
  http1:
    maxRequestHeadersKB: 64      # Envoy uses a single max, not count*size
```

Note: ClientTrafficPolicy targets the **Gateway**, not individual HTTPRoutes.

## Additional Common Mappings

### cors-*
```yaml
# nginx annotations
nginx.ingress.kubernetes.io/enable-cors: "true"
nginx.ingress.kubernetes.io/cors-allow-origin: "*"
nginx.ingress.kubernetes.io/cors-allow-methods: "GET, POST, OPTIONS"

# Envoy Gateway: No annotation needed for most cases.
# Envoy proxies CORS headers from the backend transparently.
# For gateway-level CORS, use SecurityPolicy:
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: SecurityPolicy
metadata:
  name: <app-name>-cors
spec:
  targetRefs:
  - group: gateway.networking.k8s.io
    kind: HTTPRoute
    name: <app-name>
  cors:
    allowOrigins:
    - type: Exact
      value: "https://my-frontend.example.com"
    allowMethods:
    - GET
    - POST
    - OPTIONS
    allowHeaders:
    - Authorization
    - Content-Type
```

### ssl-redirect
```yaml
# nginx annotation
nginx.ingress.kubernetes.io/ssl-redirect: "true"

# Envoy Gateway: Handled natively by the Gateway.
# When a Gateway has both HTTP (port 80) and HTTPS (port 443) listeners,
# configure the HTTP listener to redirect:
spec:
  listeners:
  - name: http
    protocol: HTTP
    port: 80
    # Add HTTPRoute with RequestRedirect filter:
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: http-redirect
spec:
  parentRefs:
  - name: envoy-gateway
    namespace: envoy-gateway-system
    sectionName: http
  rules:
  - filters:
    - type: RequestRedirect
      requestRedirect:
        scheme: https
        statusCode: 301
```

### permanent-redirect / temporal-redirect
```yaml
# nginx annotation
nginx.ingress.kubernetes.io/permanent-redirect: "https://new-app.example.com"

# Envoy Gateway equivalent: HTTPRoute RequestRedirect filter
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: <app-name>-redirect
spec:
  parentRefs:
  - name: envoy-gateway
    namespace: envoy-gateway-system
  hostnames:
  - "old-app.example.com"
  rules:
  - filters:
    - type: RequestRedirect
      requestRedirect:
        hostname: "new-app.example.com"
        statusCode: 301
```

### rate-limiting
```yaml
# nginx annotations
nginx.ingress.kubernetes.io/limit-rps: "10"
nginx.ingress.kubernetes.io/limit-connections: "5"

# Envoy Gateway equivalent: BackendTrafficPolicy rateLimit
# Note: Envoy rate limiting is more powerful but requires a rate limit service
# or can use local rate limiting via BackendTrafficPolicy:
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: BackendTrafficPolicy
metadata:
  name: <app-name>-btp
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: <app-name>
  rateLimit:
    type: Local
    local:
      rules:
      - limit:
          requests: 10
          unit: Second
```

### canary-* (traffic splitting)
```yaml
# nginx annotations
nginx.ingress.kubernetes.io/canary: "true"
nginx.ingress.kubernetes.io/canary-weight: "20"

# Envoy Gateway equivalent: HTTPRoute weight-based routing
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: <app-name>
spec:
  parentRefs:
  - name: envoy-gateway
    namespace: envoy-gateway-system
  hostnames:
  - "my-app.example.com"
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /
    backendRefs:
    - name: my-app-stable
      port: 8080
      weight: 80
    - name: my-app-canary
      port: 8080
      weight: 20
```

### custom-http-errors
```yaml
# nginx annotation
nginx.ingress.kubernetes.io/custom-http-errors: "404,503"

# Envoy Gateway: No direct equivalent.
# Options:
# 1. Use EnvoyPatchPolicy for custom error responses (advanced)
# 2. Handle error pages in the application itself
# 3. Use a CDN/WAF layer (e.g., Cloudflare custom error pages)
```

### rewrite-target (URL rewriting)
```yaml
# nginx annotations
nginx.ingress.kubernetes.io/rewrite-target: /$1
nginx.ingress.kubernetes.io/use-regex: "true"

# Envoy Gateway equivalent depends on whether regex is used.

# --- Simple rewrite (no regex): HTTPRoute URLRewrite filter ---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: <app-name>
spec:
  parentRefs:
    - name: envoy-gateway
      namespace: envoy-gateway-system
  hostnames:
    - "my-app.example.com"
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /old-path
      filters:
        - type: URLRewrite
          urlRewrite:
            path:
              type: ReplacePrefixMatch
              replacePrefixMatch: /new-path
      backendRefs:
        - name: my-app
          port: 8080
```

```yaml
# --- Regex rewrite: Requires HTTPRouteFilter CRD (Envoy Gateway extension) ---
# nginx uses $1, $2 for capture groups. Envoy uses \1, \2.
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: HTTPRouteFilter
metadata:
  name: <app-name>-rewrite
  namespace: <app-namespace>
spec:
  urlRewrite:
    path:
      type: RegexHTTPPathModifier
      regexHTTPPathModifier:
        pattern: '^/prefix/(.*)'
        substitution: '/api/\1'
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: <app-name>
spec:
  parentRefs:
    - name: envoy-gateway
      namespace: envoy-gateway-system
  hostnames:
    - "my-app.example.com"
  rules:
    - matches:
        - path:
            type: RegularExpression
            value: '^/prefix/(.*)'
      filters:
        - type: ExtensionRef
          extensionRef:
            group: gateway.envoyproxy.io
            kind: HTTPRouteFilter
            name: <app-name>-rewrite
      backendRefs:
        - name: my-app
          port: 8080
```

### whitelist-source-range / denylist-source-range (IP filtering)
```yaml
# nginx annotations
nginx.ingress.kubernetes.io/whitelist-source-range: "10.0.0.0/8,172.16.0.0/12"
# or
nginx.ingress.kubernetes.io/denylist-source-range: "192.168.1.0/24"

# Envoy Gateway equivalent: SecurityPolicy with authorization rules
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: SecurityPolicy
metadata:
  name: <app-name>-ip-filter
  namespace: <app-namespace>
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: <app-name>
  authorization:
    defaultAction: Deny
    rules:
      - name: allow-internal
        action: Allow
        principal:
          clientCIDRs:
            - "10.0.0.0/8"
            - "172.16.0.0/12"
```

For a denylist pattern (allow all except specific ranges):

```yaml
spec:
  authorization:
    defaultAction: Allow
    rules:
      - name: deny-range
        action: Deny
        principal:
          clientCIDRs:
            - "192.168.1.0/24"
```

### proxy-next-upstream / proxy-next-upstream-tries (Retry policy)
```yaml
# nginx annotations
nginx.ingress.kubernetes.io/proxy-next-upstream: "error timeout http_503"
nginx.ingress.kubernetes.io/proxy-next-upstream-tries: "3"

# Envoy Gateway equivalent: BackendTrafficPolicy retry
# nginx "tries" includes the initial attempt; Envoy "numRetries" is retries only.
# So nginx tries=3 means Envoy numRetries=2.
#
# nginx trigger mapping to Envoy:
#   "error"    -> ConnectFailure, ResetBeforeRequest, RefusedStream
#   "timeout"  -> ConnectFailure, Reset
#   "http_5XX" -> RetriableStatusCodes + [500, 502, 503, 504]
#   "http_503" -> RetriableStatusCodes + [503]
#   "http_429" -> RetriableStatusCodes + [429]
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: BackendTrafficPolicy
metadata:
  name: <app-name>-btp
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: <app-name>
  retry:
    numRetries: 2
    retryOn:
      triggers:
        - ConnectFailure
        - ResetBeforeRequest
        - RefusedStream
        - Reset
      httpStatusCodes:
        - 503
```

### backend-protocol: GRPC
```yaml
# nginx annotation
nginx.ingress.kubernetes.io/backend-protocol: "GRPC"
# or
nginx.ingress.kubernetes.io/backend-protocol: "GRPCS"

# Envoy Gateway equivalent: Use GRPCRoute instead of HTTPRoute.
# For GRPCS (TLS to backend), combine with BackendTLSPolicy.
apiVersion: gateway.networking.k8s.io/v1
kind: GRPCRoute
metadata:
  name: <app-name>
  namespace: <app-namespace>
spec:
  parentRefs:
    - name: envoy-gateway
      namespace: envoy-gateway-system
  hostnames:
    - "grpc.example.com"
  rules:
    - backendRefs:
        - name: <app-name>
          port: 50051
```

Note: GRPCRoute is part of the standard Gateway API channel since v1.2.0.
The Gateway's HTTPS listener handles TLS termination for gRPC the same way as HTTP.
For gRPC method-level routing, use `matches` with `method` and `service` fields.

### ssl-passthrough
```yaml
# nginx annotation
nginx.ingress.kubernetes.io/ssl-passthrough: "true"

# Envoy Gateway equivalent: TLSRoute with a Passthrough listener on the Gateway.
#
# Step 1: Add a TLS Passthrough listener to the Gateway
# (in addition to existing HTTP/HTTPS listeners)
# spec:
#   listeners:
#     - name: tls-passthrough
#       protocol: TLS
#       port: 443
#       hostname: "passthrough.example.com"
#       tls:
#         mode: Passthrough
#       allowedRoutes:
#         namespaces:
#           from: All
#
# Step 2: Create a TLSRoute (NOT an HTTPRoute)
apiVersion: gateway.networking.k8s.io/v1alpha2
kind: TLSRoute
metadata:
  name: <app-name>-passthrough
  namespace: <app-namespace>
spec:
  parentRefs:
    - name: envoy-gateway
      namespace: envoy-gateway-system
      sectionName: tls-passthrough
  hostnames:
    - "passthrough.example.com"
  rules:
    - backendRefs:
        - name: <app-name>
          port: 443
```

Note: TLSRoute requires the experimental Gateway API CRDs to be installed.
SSL passthrough means Envoy does NOT terminate TLS -- the backend must handle it.

### x-forwarded-prefix (Header manipulation)
```yaml
# nginx annotation
nginx.ingress.kubernetes.io/x-forwarded-prefix: "/api/v1"

# Envoy Gateway equivalent: HTTPRoute RequestHeaderModifier filter
spec:
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      filters:
        - type: RequestHeaderModifier
          requestHeaderModifier:
            set:
              - name: X-Forwarded-Prefix
                value: "/api/v1"
      backendRefs:
        - name: my-app
          port: 8080
```

### upstream-vhost
```yaml
# nginx annotation
nginx.ingress.kubernetes.io/upstream-vhost: "internal-service.local"

# Envoy Gateway equivalent: HTTPRoute URLRewrite filter (hostname only)
spec:
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      filters:
        - type: URLRewrite
          urlRewrite:
            hostname: "internal-service.local"
      backendRefs:
        - name: my-app
          port: 8080
```

### proxy-ssl-* (Advanced backend TLS)
```yaml
# nginx annotations for granular backend TLS
nginx.ingress.kubernetes.io/proxy-ssl-secret: "my-namespace/client-cert-secret"
nginx.ingress.kubernetes.io/proxy-ssl-verify: "on"
nginx.ingress.kubernetes.io/proxy-ssl-name: "backend.internal.svc"
nginx.ingress.kubernetes.io/proxy-ssl-server-name: "on"

# Envoy Gateway equivalent: BackendTLSPolicy
# Handles CA validation and SNI hostname.
apiVersion: gateway.networking.k8s.io/v1alpha3
kind: BackendTLSPolicy
metadata:
  name: <app-name>-backend-tls
  namespace: <app-namespace>
spec:
  targetRefs:
    - group: ""
      kind: Service
      name: <backend-service>
  validation:
    caCertificateRefs:
      - name: <ca-secret>
        group: ""
        kind: Secret
    hostname: "backend.internal.svc"
```

For mTLS to upstreams (client certificate), use the Envoy Gateway `Backend` CRD:

```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: Backend
metadata:
  name: <app-name>-backend
  namespace: <app-namespace>
spec:
  endpoints:
    - fqdn:
        hostname: <backend-service>.<namespace>.svc.cluster.local
        port: 443
  appProtocols:
    - gateway.envoyproxy.io/h2c
  tls:
    caCertificateRefs:
      - name: <ca-secret>
        kind: Secret
        group: ""
    clientCertificateRef:
      name: <client-cert-secret>
      kind: Secret
      group: ""
    sni: "backend.internal.svc"
```

### Cross-Namespace References (ReferenceGrant)
```yaml
# When an HTTPRoute references a Service or Secret in a different namespace,
# Gateway API requires a ReferenceGrant in the target namespace.
#
# Common scenarios:
# - App HTTPRoute → oauth2-proxy Service in a shared auth namespace
# - SecurityPolicy → auth Secret in a different namespace
# - HTTPRoute → shared backend Service

# Example: Allow HTTPRoutes in my-app namespace to reference Services in auth namespace
apiVersion: gateway.networking.k8s.io/v1beta1
kind: ReferenceGrant
metadata:
  name: allow-my-app-to-auth
  namespace: auth                        # Target namespace (where the Service lives)
spec:
  from:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      namespace: my-app                  # Source namespace (where the HTTPRoute lives)
  to:
    - group: ""
      kind: Service

# Example: Allow SecurityPolicies to reference Secrets across namespaces
---
apiVersion: gateway.networking.k8s.io/v1beta1
kind: ReferenceGrant
metadata:
  name: allow-policy-to-secrets
  namespace: shared-secrets
spec:
  from:
    - group: gateway.envoyproxy.io
      kind: SecurityPolicy
      namespace: my-app
  to:
    - group: ""
      kind: Secret
```

Without a ReferenceGrant, cross-namespace references are silently rejected.
Always deploy the ReferenceGrant in the **target** namespace (where the resource being referenced lives).

## No Direct Equivalent

### http-snippet (ConfigMap level)
The nginx ConfigMap `http-snippet` (e.g., `map $status $log_level`) has no direct Envoy equivalent.
Options:
1. Use `EnvoyProxy.spec.telemetry.accessLog` with JSON format (recommended)
2. Use `EnvoyPatchPolicy` for custom Envoy bootstrap config
3. Move log-level classification to the log pipeline (Fluent Bit / Vector)

### ConfigMap-level settings
nginx ConfigMap keys like `use-forwarded-headers`, `compute-full-forwarded-for`, `proxy-buffer-size`, etc.
are cluster-wide settings that do not map 1:1 to Envoy Gateway CRDs. Envoy Gateway uses:
- **ClientTrafficPolicy** for client-facing settings (per-Gateway)
- **EnvoyProxy** resource for global proxy configuration
- **EnvoyPatchPolicy** for low-level Envoy config patches

### pathType: ImplementationSpecific
Gateway API only supports: `Exact`, `PathPrefix`, `RegularExpression`.
If your nginx Ingress uses `pathType: ImplementationSpecific` with `path: /`, use `PathPrefix: /`.
For regex-based paths, use `type: RegularExpression`.

## Quick Reference Table

| nginx Annotation | Envoy Gateway CRD | Field Path |
|---|---|---|
| `proxy-body-size` | BackendTrafficPolicy | `spec.requestBuffer.limit` |
| `proxy-read-timeout` | BackendTrafficPolicy | `spec.timeout.http.requestTimeout` |
| `proxy-send-timeout` | BackendTrafficPolicy | `spec.timeout.http.requestTimeout` |
| `proxy-connect-timeout` | BackendTrafficPolicy | `spec.timeout.tcp.connectTimeout` |
| `websocket-services` | (none needed) | Native support |
| `affinity: cookie` | BackendTrafficPolicy | `spec.loadBalancer.consistentHash.cookie` |
| `tls-acme` | Gateway | `spec.listeners[].tls.certificateRefs` |
| `auth-url` / `auth-signin` | HTTPRoute (reverse proxy) | Route to oauth2-proxy service |
| `auth-type: basic` | SecurityPolicy | `spec.basicAuth.users` |
| `backend-protocol: HTTPS` | BackendTLSPolicy | `spec.targetRefs` + `spec.validation` |
| `large-client-header-buffers` | ClientTrafficPolicy | `spec.http1.maxRequestHeadersKB` |
| `ssl-redirect` | HTTPRoute | `filters[].requestRedirect.scheme: https` |
| `permanent-redirect` | HTTPRoute | `filters[].requestRedirect` |
| `limit-rps` | BackendTrafficPolicy | `spec.rateLimit.local.rules` |
| `canary-weight` | HTTPRoute | `spec.rules[].backendRefs[].weight` |
| `enable-cors` | SecurityPolicy | `spec.cors` |
| `rewrite-target` | HTTPRoute / HTTPRouteFilter | `filters[].urlRewrite` or `ExtensionRef` for regex |
| `whitelist-source-range` | SecurityPolicy | `spec.authorization.rules[].principal.clientCIDRs` |
| `denylist-source-range` | SecurityPolicy | `spec.authorization` (defaultAction: Allow + Deny rule) |
| `proxy-next-upstream` | BackendTrafficPolicy | `spec.retry.retryOn.triggers` + `httpStatusCodes` |
| `proxy-next-upstream-tries` | BackendTrafficPolicy | `spec.retry.numRetries` (nginx tries - 1) |
| `backend-protocol: GRPC` | GRPCRoute | Use GRPCRoute instead of HTTPRoute |
| `ssl-passthrough` | TLSRoute | TLS Passthrough listener + TLSRoute (experimental CRDs) |
| `x-forwarded-prefix` | HTTPRoute | `filters[].requestHeaderModifier.set` |
| `upstream-vhost` | HTTPRoute | `filters[].urlRewrite.hostname` |
| `proxy-ssl-*` | BackendTLSPolicy / Backend | `spec.validation` or Backend CRD for mTLS |
| `app-root` | HTTPRoute | `filters[].requestRedirect` (redirect `/` to app root) |
| `custom-http-errors` | EnvoyPatchPolicy | No direct mapping |
| `http-snippet` | EnvoyProxy / EnvoyPatchPolicy | No direct mapping |
