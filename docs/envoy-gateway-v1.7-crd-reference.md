# Envoy Gateway v1.7.0 CRD Quick Reference

A practical reference for the Envoy Gateway policy CRDs. Focuses on fields
that exist, fields that do NOT exist (common source of confusion), and correct
value formats.

This is not a full API reference -- see the
[official docs](https://gateway.envoyproxy.io/docs/) for that. This document
highlights the fields you actually need during an ingress-nginx migration and
the traps that catch people.

---

## BackendTrafficPolicy

Controls how Envoy communicates with upstream backends.

### Commonly Used Fields

```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: BackendTrafficPolicy
metadata:
  name: my-policy
  namespace: my-app
spec:
  targetRefs:                          # List (plural), not singular targetRef
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: my-route

  # Timeouts
  timeout:
    http:
      requestTimeout: "300s"           # Per-request timeout (maps to nginx proxy-read-timeout)
      connectionIdleTimeout: "60s"     # How long to keep idle connections open
      maxConnectionDuration: "0s"      # 0 = unlimited
    tcp:
      connectTimeout: "10s"

  # Load balancing
  loadBalancer:
    type: ConsistentHash               # or RoundRobin, LeastRequest, Random
    consistentHash:
      type: Cookie
      cookie:
        name: SESSION_AFFINITY
        ttl: "3600s"                   # String duration
        attributes:
          SameSite: Lax
          Secure: "true"

  # Request body buffer limit
  requestBuffer:
    limit: "10Mi"                      # resource.Quantity (Mi, Gi, Ki)

  # Retry policy (maps to nginx proxy-next-upstream)
  retry:
    numRetries: 2                      # Number of RETRIES, not total tries
                                       # nginx tries=3 means numRetries=2
    retryOn:
      triggers:                        # Envoy retry trigger enums
        - ConnectFailure               # nginx "error"
        - Reset                        # nginx "timeout"
        - ResetBeforeRequest
        - RefusedStream
      httpStatusCodes:                 # nginx "http_503", "http_5XX", etc.
        - 503

  # Local rate limiting (maps to nginx limit-rps / limit-rpm)
  rateLimit:
    type: Local
    local:
      rules:
        - limit:
            requests: 10
            unit: Second               # Second | Minute | Hour
```

### Fields That DO NOT Exist

| Field Path | Common Mistake | Correct Alternative |
|-----------|----------------|---------------------|
| `spec.sessionPersistence` | Docs from other projects reference this | `spec.loadBalancer.consistentHash` |
| `spec.timeout.request` | Simplified timeout field | `spec.timeout.http.connectionIdleTimeout` |

---

## ClientTrafficPolicy

Controls how Envoy handles client-facing connections.

### Commonly Used Fields

```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: ClientTrafficPolicy
metadata:
  name: my-policy
  namespace: envoy-gateway-system
spec:
  targetRefs:                          # Targets a Gateway, not HTTPRoute
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: my-gateway

  # Header handling
  headers:
    withUnderscoresAction: Allow       # Allow | RejectRequest | DropHeader
    preserveXRequestId: true

  # HTTP/1.1 settings
  http1:
    enableTrailers: false
    http10: {}

  # TLS settings (client-to-Envoy)
  tls:
    minVersion: "1.2"
    maxVersion: "1.3"
    ciphers:
      - TLS_AES_128_GCM_SHA256
      - TLS_AES_256_GCM_SHA384
```

### Fields That DO NOT Exist

| Field Path | Common Mistake | Correct Alternative |
|-----------|----------------|---------------------|
| `spec.clientRequestBody` | nginx `client_max_body_size` equivalent | `BackendTrafficPolicy.spec.requestBuffer.limit` |
| `spec.requestTimeout` | Per-request timeout | Use `BackendTrafficPolicy.spec.timeout` |

### Important Note

`ClientTrafficPolicy` targets a **Gateway**, not an HTTPRoute. It applies to
all traffic entering through that Gateway. For per-route settings, use
`BackendTrafficPolicy`.

---

## SecurityPolicy

Controls authentication and authorization for routes.

### basicAuth

```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: SecurityPolicy
metadata:
  name: basic-auth
  namespace: my-app
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: my-route
  basicAuth:
    users:
      name: htpasswd-secret            # Secret with .htpasswd key
```

The referenced Secret must have a `.htpasswd` key containing entries in SHA
hash format:

```
username:{SHA}base64encodedsha1hash=
```

bcrypt (`$2y$`) is NOT supported. Use `htpasswd -s -nb user pass` to generate.

### extAuth (HTTP)

```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: SecurityPolicy
metadata:
  name: ext-auth
  namespace: my-app
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: my-route
  extAuth:
    http:
      backendRefs:
        - name: auth-service
          namespace: auth
          port: 9090
      headersToBackend:
        - "Authorization"
        - "X-Api-Key"
      failOpen: false                  # Deny if auth service is unreachable
```

**WARNING:** Do not use extAuth with oauth2-proxy or any auth service that
relies on 302 redirects. Envoy's ext_authz filter strips `Location` headers
from auth responses. See
[auth-migration-patterns.md](auth-migration-patterns.md).

### extAuth (gRPC)

```yaml
spec:
  extAuth:
    grpc:
      backendRefs:
        - name: auth-service-grpc
          port: 9091
```

### authorization (IP allowlist / denylist)

Maps from nginx `whitelist-source-range` and `denylist-source-range` annotations.

```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: SecurityPolicy
metadata:
  name: ip-filter
  namespace: my-app
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: my-route
  authorization:
    defaultAction: Deny                  # Deny | Allow
    rules:
      - name: allow-internal
        action: Allow                    # Allow | Deny
        principal:
          clientCIDRs:
            - "10.0.0.0/8"
            - "172.16.0.0/12"
```

For a denylist (allow all, deny specific ranges), flip the defaults:

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

### cors

Maps from nginx `enable-cors`, `cors-allow-origin`, `cors-allow-methods`, etc.

```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: SecurityPolicy
metadata:
  name: cors-policy
  namespace: my-app
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: my-route
  cors:
    allowOrigins:
      - type: Exact                      # Exact | RegularExpression
        value: "https://app.example.com"
    allowMethods:
      - GET
      - POST
      - OPTIONS
    allowHeaders:
      - Authorization
      - Content-Type
    exposeHeaders:
      - X-Custom-Header
    maxAge: "86400s"                     # String duration
    allowCredentials: true
```

---

## Value Format Reference

### String Durations

Used in timeout fields. Format: number + unit suffix.

```
"10s"     - 10 seconds
"5m"      - 5 minutes
"1h"      - 1 hour
"500ms"   - 500 milliseconds
"0s"      - unlimited / disabled
```

### resource.Quantity

Used in `requestBuffer.limit`. Follows Kubernetes resource quantity format.

```
"10Mi"    - 10 mebibytes (10 * 1024 * 1024 bytes)
"1Gi"     - 1 gibibyte
"512Ki"   - 512 kibibytes

# WRONG - these mean something completely different:
"10m"     - 10 millibytes (essentially 0)
"1g"      - NOT a valid quantity (use Gi)
```

### Enum Values

| Field | Valid Values |
|-------|-------------|
| `loadBalancer.type` | `RoundRobin`, `LeastRequest`, `Random`, `ConsistentHash` |
| `consistentHash.type` | `Cookie`, `Header`, `SourceIP` |
| `withUnderscoresAction` | `Allow`, `RejectRequest`, `DropHeader` |
| `tls.minVersion` / `maxVersion` | `"1.0"`, `"1.1"`, `"1.2"`, `"1.3"` |
| `rateLimit.type` | `Local`, `Global` |
| `rateLimit.local.rules[].limit.unit` | `Second`, `Minute`, `Hour` |
| `authorization.defaultAction` | `Allow`, `Deny` |
| `authorization.rules[].action` | `Allow`, `Deny` |
| `cors.allowOrigins[].type` | `Exact`, `RegularExpression` |
| `retry.retryOn.triggers` | `ConnectFailure`, `Reset`, `ResetBeforeRequest`, `RefusedStream`, `Retriable4xx`, `RetriableStatusCodes`, `Cancelled`, `DeadlineExceeded`, `Internal`, `ResourceExhausted`, `Unavailable` |

---

## targetRef vs targetRefs

The singular `targetRef` is deprecated. Always use the plural `targetRefs`
which accepts a list:

```yaml
# Correct (current)
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: route-a
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: route-b

# Deprecated (may stop working)
spec:
  targetRef:
    group: gateway.networking.k8s.io
    kind: HTTPRoute
    name: route-a
```

The same applies to `backendRefs` (plural) vs `backendRef` (singular) in
HTTPRoute and SecurityPolicy extAuth.

---

## Mapping From ingress-nginx Annotations

| nginx Annotation | Envoy Gateway CRD | Field |
|------------------|--------------------|-------|
| `proxy-body-size` | BackendTrafficPolicy | `spec.requestBuffer.limit` |
| `proxy-read-timeout` / `proxy-send-timeout` | BackendTrafficPolicy | `spec.timeout.http.requestTimeout` |
| `proxy-connect-timeout` | BackendTrafficPolicy | `spec.timeout.tcp.connectTimeout` |
| `proxy-next-upstream` / `tries` | BackendTrafficPolicy | `spec.retry` (numRetries = nginx tries - 1) |
| `affinity: cookie` | BackendTrafficPolicy | `spec.loadBalancer.consistentHash.cookie` |
| `limit-rps` / `limit-rpm` | BackendTrafficPolicy | `spec.rateLimit.local.rules` |
| `auth-type: basic` | SecurityPolicy | `spec.basicAuth` |
| `auth-url` | SecurityPolicy | `spec.extAuth.http` (non-redirect only) |
| `whitelist-source-range` | SecurityPolicy | `spec.authorization` (defaultAction: Deny) |
| `denylist-source-range` | SecurityPolicy | `spec.authorization` (defaultAction: Allow) |
| `enable-cors` / `cors-*` | SecurityPolicy | `spec.cors` |
| `ssl-protocols` | ClientTrafficPolicy | `spec.tls.minVersion` / `maxVersion` |
| `underscores-in-headers` | ClientTrafficPolicy | `spec.headers.withUnderscoresAction` |
