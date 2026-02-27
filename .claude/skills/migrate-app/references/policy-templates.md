# Envoy Gateway Policy Templates (v1.7.0)

Helm templates for Envoy Gateway policies to include in app charts.
Verified against CRD schemas for Envoy Gateway v1.7.0.

## BackendTrafficPolicy Template

For apps needing: timeouts, cookie session affinity, or request body size limits.
All three features are in BackendTrafficPolicy (NOT ClientTrafficPolicy).

### Standalone chart template

File: `templates/backendtrafficpolicy.yaml`

```yaml
{{- if and (hasKey .Values "gatewayAPI") .Values.gatewayAPI.enabled }}
{{- $hasTimeout := and (hasKey .Values.gatewayAPI "timeout") .Values.gatewayAPI.timeout }}
{{- $hasSession := and (hasKey .Values.gatewayAPI "sessionAffinity") .Values.gatewayAPI.sessionAffinity }}
{{- $hasBuffer := and (hasKey .Values.gatewayAPI "requestBufferLimit") .Values.gatewayAPI.requestBufferLimit }}
{{- if or $hasTimeout $hasSession $hasBuffer }}
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: BackendTrafficPolicy
metadata:
  name: {{ include "<chart>.fullname" . }}-btp
  labels:
    {{- include "<chart>.labels" . | nindent 4 }}
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: {{ include "<chart>.fullname" . }}
  {{- if $hasTimeout }}
  timeout:
    {{- with .Values.gatewayAPI.timeout.http }}
    http:
      requestTimeout: {{ .requestTimeout | quote }}
    {{- end }}
    {{- with .Values.gatewayAPI.timeout.tcp }}
    tcp:
      connectTimeout: {{ .connectTimeout | quote }}
    {{- end }}
  {{- end }}
  {{- if $hasSession }}
  loadBalancer:
    type: ConsistentHash
    consistentHash:
      type: Cookie
      cookie:
        name: {{ .Values.gatewayAPI.sessionAffinity.cookieName | quote }}
        {{- with .Values.gatewayAPI.sessionAffinity.cookieTTL }}
        ttl: {{ . | quote }}
        {{- end }}
  {{- end }}
  {{- if $hasBuffer }}
  requestBuffer:
    limit: {{ .Values.gatewayAPI.requestBufferLimit }}
  {{- end }}
{{- end }}
{{- end }}
```

Replace `<chart>` with your chart's helper name prefix (e.g., `my-app`, `my-api`).

## ClientTrafficPolicy

NOT needed for most apps. In Envoy Gateway v1.7.0:
- Body size limits are in **BackendTrafficPolicy** (`requestBuffer.limit`), NOT CTP
- CTP is for: client IP detection, connection settings, proxy protocol, HTTP/1/2/3 settings, TLS client settings, header handling
- Use CTP if your app requires large request headers (`http1.maxRequestHeadersKB`)
- **Important**: CTP targets the **Gateway**, not individual HTTPRoutes

One CTP that is commonly needed at the cluster level:

```yaml
# Required if traffic passes through a CDN/proxy that sends headers with underscores.
# Envoy rejects headers with underscores by default (nginx allows them).
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: ClientTrafficPolicy
metadata:
  name: allow-underscore-headers
  namespace: envoy-gateway-system
spec:
  targetRefs:
  - group: gateway.networking.k8s.io
    kind: Gateway
    name: envoy-gateway
    namespace: envoy-gateway-system
  headers:
    withUnderscoresAction: Allow
```

## Values Structure

```yaml
gatewayAPI:
  enabled: false                     # NEVER set true in root values.yaml
  gatewayName: "envoy-gateway"
  gatewayNamespace: "envoy-gateway-system"
  # Request body size limit (Kubernetes resource.Quantity format)
  # Maps to BTP spec.requestBuffer.limit. Rejects >limit with HTTP 413.
  # NOTE: Buffers entire request body before forwarding (unlike nginx which streams).
  requestBufferLimit: ""             # e.g. "10Mi", "512Mi", "2Gi"
  # Timeouts
  # Maps to BTP spec.timeout
  timeout:
    http:
      requestTimeout: ""             # e.g. "300s", "3600s"
    tcp:
      connectTimeout: ""             # e.g. "60s"
  # Cookie-based session affinity
  # Maps to BTP spec.loadBalancer.consistentHash.cookie
  sessionAffinity:
    cookieName: ""                   # e.g. "my_route", "SERVERID"
    cookieTTL: ""                    # e.g. "3600s", "86400s"
```

**Important**: Only set `gatewayAPI.enabled: true` in environment-specific values files
(e.g., `dev-values.yaml`, `staging-values.yaml`), never in the root `values.yaml`.
This limits blast radius to one cluster at a time.

## CRD Field Reference (v1.7.0)

Verified via `kubectl explain` on live clusters:

| Feature | CRD | Field Path | Format |
|---------|-----|------------|--------|
| Request timeout | BTP | `spec.timeout.http.requestTimeout` | string, e.g. `"300s"` |
| Connect timeout | BTP | `spec.timeout.tcp.connectTimeout` | string, e.g. `"60s"` |
| Cookie affinity | BTP | `spec.loadBalancer.consistentHash.cookie.{name,ttl}` | string |
| Body size limit | BTP | `spec.requestBuffer.limit` | resource.Quantity, e.g. `512Mi` |
| Rate limiting | BTP | `spec.rateLimit.local.rules` | object |
| Target reference | BTP | `spec.targetRefs[].{group,kind,name}` | list of refs |
| Header size | CTP | `spec.http1.maxRequestHeadersKB` | integer (KB) |
| Underscore headers | CTP | `spec.headers.withUnderscoresAction` | `Allow` or `RejectRequest` |
| Target reference | CTP | `spec.targetRefs[].{group,kind,name}` | list of refs |

**Fields that do NOT exist in v1.7.0 (despite appearing in some documentation):**
- ~~`BTP.spec.sessionPersistence`~~ -- does not exist, use `loadBalancer.consistentHash`
- ~~`CTP.spec.clientRequestBody`~~ -- does not exist, use BTP `requestBuffer.limit`

## SecurityPolicy extAuth Template

File: `templates/securitypolicy.yaml`

**WARNING**: Do NOT use extAuth with oauth2-proxy. Envoy strips Location headers,
breaking browser redirects to the login page. Use the reverse proxy pattern instead
(see annotation-mapping.md). This template is only for non-oauth2-proxy auth services.

```yaml
{{- if and (hasKey .Values "gatewayAPI") .Values.gatewayAPI.enabled }}
{{- if .Values.gatewayAPI.extAuth }}
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: SecurityPolicy
metadata:
  name: {{ include "<chart>.fullname" . }}-auth
  labels:
    {{- include "<chart>.labels" . | nindent 4 }}
spec:
  targetRefs:
  - group: gateway.networking.k8s.io
    kind: HTTPRoute
    name: {{ include "<chart>.fullname" . }}
  extAuth:
    http:
      backendRef:
        name: {{ .Values.gatewayAPI.extAuth.serviceName }}
        port: {{ .Values.gatewayAPI.extAuth.servicePort }}
      path: {{ .Values.gatewayAPI.extAuth.path }}
      {{- with .Values.gatewayAPI.extAuth.headersToBackend }}
      headersToBackend:
        {{- toYaml . | nindent 8 }}
      {{- end }}
{{- end }}
{{- end }}
```

## SecurityPolicy basicAuth Template

File: `templates/securitypolicy-basic-auth.yaml`

```yaml
{{- if and (hasKey .Values "gatewayAPI") .Values.gatewayAPI.enabled }}
{{- if .Values.gatewayAPI.basicAuth }}
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: SecurityPolicy
metadata:
  name: {{ include "<chart>.fullname" . }}-basic-auth
  labels:
    {{- include "<chart>.labels" . | nindent 4 }}
spec:
  targetRefs:
  - group: gateway.networking.k8s.io
    kind: HTTPRoute
    name: {{ include "<chart>.fullname" . }}
  basicAuth:
    users:
      name: {{ .Values.gatewayAPI.basicAuth.secretName }}
{{- end }}
{{- end }}
```

### SecurityPolicy Values Structure

```yaml
gatewayAPI:
  # External auth (for non-oauth2-proxy auth services ONLY)
  extAuth:
    serviceName: "my-auth-service"
    servicePort: 8080
    path: "/auth/check"
    headersToBackend:
    - Authorization
    - X-Auth-User
  # Basic auth (htpasswd)
  basicAuth:
    secretName: "my-basic-auth"      # Opaque Secret with ".htpasswd" key (SHA hash only)
```

### SecurityPolicy CRD Field Reference (v1.7.0)

| Feature | CRD | Field Path |
|---------|-----|------------|
| External auth | SecurityPolicy | `spec.extAuth.http.{backendRef,path,headersToBackend}` |
| Basic auth | SecurityPolicy | `spec.basicAuth.users` (ref to Secret with `.htpasswd` key) |
| CORS | SecurityPolicy | `spec.cors.{allowOrigins,allowMethods,allowHeaders}` |
| Target reference | SecurityPolicy | `spec.targetRefs[].{group,kind,name}` (use plural `targetRefs`) |

## Example Values: WebSocket App with Session Affinity

```yaml
gatewayAPI:
  enabled: true
  timeout:
    http:
      requestTimeout: "3600s"
  sessionAffinity:
    cookieName: "SERVERID"
    cookieTTL: "86400s"
```

## Example Values: File Upload App (Body Size Only)

```yaml
gatewayAPI:
  enabled: true
  requestBufferLimit: 2Gi
```

## Example Values: API with Session Affinity + Timeout + Body Size

```yaml
gatewayAPI:
  enabled: true
  requestBufferLimit: 10Mi
  timeout:
    http:
      requestTimeout: "300s"
  sessionAffinity:
    cookieName: "my_route"
    cookieTTL: "3600s"
```

## Example Values: Basic Auth Protected App

```yaml
gatewayAPI:
  enabled: true
  basicAuth:
    secretName: "my-app-htpasswd"
```

With the corresponding Secret:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: my-app-htpasswd
type: Opaque
stringData:
  .htpasswd: |
    admin:{SHA}W6ph5Mm5Pz8GgiULbPgzG37mj9g=
```
