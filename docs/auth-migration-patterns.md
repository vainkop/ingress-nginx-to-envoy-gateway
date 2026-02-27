# Auth Migration Patterns: ingress-nginx to Envoy Gateway

ingress-nginx uses `auth-url` and `auth-signin` annotations to integrate with
external auth services like oauth2-proxy. Envoy Gateway uses `SecurityPolicy`
resources. The mapping is not 1:1, and choosing the wrong pattern causes subtle
breakages.

This document covers three patterns, when to use each, and why the most
"obvious" approach (extAuth with oauth2-proxy) is actually broken for browser
flows.

---

## Pattern A: oauth2-proxy as Reverse Proxy (RECOMMENDED for Browser Flows)

### When to Use

Any application that requires browser-based OIDC/OAuth2 login via
oauth2-proxy. This is the recommended pattern for all web applications.

### Architecture

```
                          +------------------+
                          |    CDN / DNS     |
                          +--------+---------+
                                   |
                          +--------v---------+
                          |  Envoy Gateway   |
                          |  (HTTPRoute)     |
                          +--------+---------+
                                   |
                          +--------v---------+
                          |  oauth2-proxy    |
                          |  (handles auth)  |
                          +--------+---------+
                                   |
                          +--------v---------+
                          |  Application     |
                          |  (upstream)      |
                          +------------------+
```

All traffic flows through oauth2-proxy. oauth2-proxy handles authentication
and forwards authenticated requests to the application backend via
`OAUTH2_PROXY_UPSTREAMS`.

### How It Works

1. User requests `https://app.example.com/dashboard`
2. Envoy routes ALL traffic for `app.example.com` to the oauth2-proxy Service
3. oauth2-proxy checks for a valid session cookie
4. If not authenticated: oauth2-proxy returns a 302 redirect to the IdP
   (this works because oauth2-proxy IS the backend, not an ext_authz filter)
5. After IdP login, oauth2-proxy sets a session cookie and proxies the
   request to the upstream application

### oauth2-proxy Configuration

```yaml
# oauth2-proxy deployment values (key settings)
OAUTH2_PROXY_UPSTREAMS: "http://my-app-service.my-app.svc.cluster.local:8080"
OAUTH2_PROXY_COOKIE_DOMAINS: ".example.com"
OAUTH2_PROXY_WHITELIST_DOMAINS: ".example.com"
```

### HTTPRoute

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: my-app
  namespace: my-app
spec:
  parentRefs:
    - name: my-gateway
      namespace: envoy-gateway-system
  hostnames:
    - "app.example.com"
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: oauth2-proxy
          namespace: my-app-auth
          port: 4180
```

Note: the HTTPRoute points to **oauth2-proxy**, not the application. There is
no SecurityPolicy needed. oauth2-proxy handles both authentication and
forwarding.

If the oauth2-proxy is in a different namespace, you need a `ReferenceGrant`:

```yaml
apiVersion: gateway.networking.k8s.io/v1beta1
kind: ReferenceGrant
metadata:
  name: allow-httproute-to-oauth2-proxy
  namespace: my-app-auth
spec:
  from:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      namespace: my-app
  to:
    - group: ""
      kind: Service
```

---

## Pattern B: SecurityPolicy basicAuth (API Endpoints, CI/CD)

### When to Use

Simple username/password protection for non-browser clients: CI/CD pipelines,
API endpoints, internal tools. No IdP redirect needed.

### .htpasswd Secret

Envoy requires SHA1 hashes. bcrypt (`$2y$` prefix) is NOT supported.

```bash
# Generate with SHA hash (-s flag)
htpasswd -s -nb myuser mypassword
# Output: myuser:{SHA}W6ph5Mm5Pz8GgiULbPgzG37mj9g=
```

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: basic-auth-credentials
  namespace: my-app
type: Opaque
stringData:
  .htpasswd: |
    myuser:{SHA}W6ph5Mm5Pz8GgiULbPgzG37mj9g=
    ci-bot:{SHA}aBcDeFgHiJkLmNoPqRsTuVwXyZ0=
```

### SecurityPolicy

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
      name: my-app-route
  basicAuth:
    users:
      name: basic-auth-credentials
```

### HTTPRoute

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: my-app-route
  namespace: my-app
spec:
  parentRefs:
    - name: my-gateway
      namespace: envoy-gateway-system
  hostnames:
    - "app.example.com"
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: my-app-service
          port: 8080
```

The SecurityPolicy attaches to the HTTPRoute by name. Requests without valid
Basic auth credentials receive a 401 response.

---

## Pattern C: SecurityPolicy extAuth (Non-Redirect Auth)

### When to Use

External authorization for **machine-to-machine** traffic: API key validation,
JWT verification, custom auth services that return 200 (allow) or 403 (deny)
without needing browser redirects.

### IMPORTANT: Do NOT Use for oauth2-proxy

extAuth is NOT compatible with browser-based OIDC redirect flows. See the
explanation below.

### SecurityPolicy

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
      name: my-api-route
  extAuth:
    http:
      backendRefs:
        - name: auth-service
          namespace: my-app
          port: 9090
      headersToBackend:
        - "Authorization"
        - "X-Api-Key"
```

The external auth service receives a check request and returns:

- **200**: Request is allowed, forwarded to the backend
- **401/403**: Request is denied, error returned to client

---

## Why extAuth Breaks Browser OIDC Redirects

When using `SecurityPolicy` with `extAuth` pointing to oauth2-proxy:

1. Unauthenticated user requests `https://app.example.com/dashboard`
2. Envoy sends an authorization check to oauth2-proxy
3. oauth2-proxy returns HTTP 302 with `Location: https://idp.example.com/authorize?...`
4. **Envoy's ext_authz filter strips the `Location` header** from the
   auth response before returning it to the client
5. The client receives a 302 with no `Location` header
6. The browser cannot redirect -- the login flow is broken

This is a fundamental behavior of Envoy's ext_authz implementation. The filter
only forwards specific "allowed" headers from the auth response, and `Location`
is not in the default allow list. While it may be possible to configure
additional allowed headers, the behavior is fragile and differs from what
ingress-nginx's `auth-url`/`auth-signin` annotations provide.

**The reverse proxy pattern (Pattern A) avoids this entirely** because
oauth2-proxy is the actual backend, not a sidecar filter. It controls the full
HTTP response including `Location` headers.

---

## Migration Decision Matrix

| Auth Type | nginx Annotation | Envoy Pattern | Notes |
|-----------|-----------------|---------------|-------|
| oauth2-proxy (browser) | `auth-url` + `auth-signin` | Pattern A: Reverse proxy | Route traffic TO oauth2-proxy |
| Basic auth | `auth-type: basic` | Pattern B: SecurityPolicy basicAuth | SHA hash required |
| API key validation | `auth-url` (API) | Pattern C: SecurityPolicy extAuth | No browser redirect needed |
| JWT validation | `auth-url` (API) | Pattern C: SecurityPolicy extAuth | Or use Envoy JWT filter |

---

## Common Mistakes

1. **Using extAuth with oauth2-proxy** -- login redirects break silently
2. **bcrypt hash in .htpasswd** -- all requests get 401
3. **Using singular `targetRef`** -- deprecated, use `targetRefs` (list)
4. **Forgetting ReferenceGrant** -- cross-namespace backendRefs fail silently
5. **Not migrating oauth2-proxy Ingress and app Ingress together** -- if
   oauth2-proxy's `/oauth2/*` path is still on nginx while the app is on
   Envoy, the callback URL breaks
