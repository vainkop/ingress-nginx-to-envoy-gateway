---
name: analyze-ingress
description: >
  Analyzes a live Ingress resource and classifies its migration complexity to Envoy Gateway.
  Produces a detailed report mapping each nginx annotation to its Envoy Gateway equivalent.
  Use when "analyze ingress for X", "what does X need for migration", "classify X complexity",
  "check annotations on X".
license: Apache-2.0
metadata:
  author: vainkop
  version: 1.0.0
  tags: [analysis, ingress, pre-migration, annotations]
---

# Analyze Ingress Resource for Migration

This skill examines a live ingress-nginx Ingress resource (or YAML file), maps every annotation
to its Envoy Gateway equivalent, identifies required Gateway API resources, classifies overall
migration complexity, and flags known gotchas.

## Prerequisites

- `kubectl` access to the cluster containing the Ingress, OR a YAML file of the Ingress
- Knowledge of the app's namespace and Ingress resource name

## Procedure

### Step 1: Get the Ingress YAML

**From a live cluster:**

```bash
kubectl get ingress <name> -n <namespace> -o yaml
```

**From a file:**

Read the provided YAML file directly.

Record the full Ingress spec including all annotations, TLS configuration, rules, and backend references.

### Step 2: Parse and Map All Annotations

For each `nginx.ingress.kubernetes.io/*` annotation on the Ingress, determine the
Envoy Gateway equivalent resource and field.

**Complete annotation mapping reference:**

#### Routing Annotations (handled by HTTPRoute)

| nginx Annotation | Envoy Equivalent | Notes |
|-----------------|------------------|-------|
| `rewrite-target` | HTTPRoute `urlRewrite` filter | Regex rewrite via `RegexHTTPPathModifier` |
| `app-root` | HTTPRoute `requestRedirect` filter | Redirect `/` to the target path |
| `use-regex` | HTTPRoute `RegularExpression` path match | Envoy supports RE2 regex |
| `ssl-redirect: "true"` | HTTPRoute `requestRedirect` filter | `scheme: https`, `statusCode: 301` |
| `force-ssl-redirect` | Same as ssl-redirect | |
| `temporal-redirect` | HTTPRoute `requestRedirect` filter | `statusCode: 302` |
| `permanent-redirect` | HTTPRoute `requestRedirect` filter | `statusCode: 301` |
| `upstream-hash-by` | BackendTrafficPolicy `loadBalancer.consistentHash` | Header or cookie hash |

#### Backend Traffic Annotations (BackendTrafficPolicy)

| nginx Annotation | BTP Field | Type/Notes |
|-----------------|-----------|------------|
| `proxy-read-timeout` | `spec.timeout.http.requestTimeout` | Duration string (e.g., `"60s"`) |
| `proxy-send-timeout` | `spec.timeout.http.requestTimeout` | Combined with read timeout |
| `proxy-connect-timeout` | `spec.timeout.tcp.connectTimeout` | Duration string |
| `proxy-body-size` | `spec.requestBuffer.limit` | resource.Quantity (e.g., `"10Mi"`) |
| `proxy-buffering` | N/A (Envoy buffers by default) | No direct equivalent |
| `proxy-buffer-size` | N/A | Envoy manages buffers automatically |
| `affinity: cookie` | `spec.loadBalancer.consistentHash.cookie` | NOT `spec.sessionPersistence` (does not exist in v1.7.0) |
| `session-cookie-name` | `spec.loadBalancer.consistentHash.cookie.name` | |
| `session-cookie-max-age` | `spec.loadBalancer.consistentHash.cookie.ttl` | Duration string |
| `session-cookie-path` | `spec.loadBalancer.consistentHash.cookie.attributes.path` | |
| `cors-allow-origin` | `spec.cors.allowOrigins` | Array of `StringMatch` |
| `cors-allow-methods` | `spec.cors.allowMethods` | String array |
| `cors-allow-headers` | `spec.cors.allowHeaders` | String array |
| `cors-expose-headers` | `spec.cors.exposeHeaders` | String array |
| `cors-allow-credentials` | `spec.cors.allowCredentials` | Boolean |
| `cors-max-age` | `spec.cors.maxAge` | Duration string |
| `limit-rps` | `spec.rateLimit.local.rules` | Rate limit configuration |
| `limit-connections` | `spec.rateLimit.local.rules` | Connection-based rate limit |
| `enable-cors` | `spec.cors` (presence) | Enable CORS with explicit origins |

#### Auth Annotations (SecurityPolicy or Routing)

| nginx Annotation | Envoy Equivalent | Notes |
|-----------------|------------------|-------|
| `auth-type: basic` | SecurityPolicy `spec.basicAuth` | Needs Secret with `.htpasswd` key (SHA hash, NOT bcrypt) |
| `auth-secret` | SecurityPolicy `spec.basicAuth.users` | Secret reference |
| `auth-url` + `auth-signin` | **DO NOT use SecurityPolicy extAuth** | Route through oauth2-proxy as reverse proxy instead |
| `auth-response-headers` | N/A with reverse proxy pattern | oauth2-proxy handles header forwarding internally |

#### Client/Connection Annotations (ClientTrafficPolicy or N/A)

| nginx Annotation | Envoy Equivalent | Notes |
|-----------------|------------------|-------|
| `proxy-protocol` | ClientTrafficPolicy `spec.proxyProtocol` | Rarely needed |
| `enable-access-log` | EnvoyProxy telemetry (cluster-level) | Not per-route in Envoy |
| `server-snippet` | N/A | No equivalent -- must find alternative approach |
| `configuration-snippet` | N/A | No equivalent -- must find alternative approach |
| `client-header-timeout` | ClientTrafficPolicy `spec.timeout.http.requestReceivedTimeout` | Rarely needed |
| `large-client-header-buffers` | N/A | Envoy manages automatically |

#### Annotations with No Direct Equivalent

| nginx Annotation | Status | Workaround |
|-----------------|--------|------------|
| `server-snippet` | Not supported | Evaluate what the snippet does and find Envoy-native approach |
| `configuration-snippet` | Not supported | Same as above |
| `modsecurity-*` | Not supported | Use external WAF (CDN-level or dedicated) |
| `custom-http-errors` | Partial | `BackendTrafficPolicy.spec.responseOverride` (limited) |
| `default-backend` | Partial | Add a catch-all HTTPRoute rule |

### Step 3: Identify Required Resources

Based on the annotation mapping, determine which Gateway API resources are needed:

1. **HTTPRoute** (always required)
2. **BackendTrafficPolicy** -- if any timeout, body size, CORS, rate limit, or affinity annotations exist
3. **SecurityPolicy** -- if basic auth is used (NOT for oauth2-proxy)
4. **Gateway listener** -- HTTPS listener for the app's hostname (if not already present)
5. **TLS Secret copy** -- Secret must exist in Gateway namespace before DNS cutover

List each resource with its required fields populated from the Ingress annotations.

### Step 4: Classify Overall Complexity

| Level | Criteria | Estimated Effort |
|-------|----------|-----------------|
| **Simple** | HTTPRoute only. No special annotations beyond TLS and basic routing. | 15-30 min |
| **Medium** | HTTPRoute + BackendTrafficPolicy. Has timeout, body size, or affinity annotations. | 30-60 min |
| **Complex** | HTTPRoute + BackendTrafficPolicy + SecurityPolicy (basic auth). Or has CORS, rate limiting. | 1-2 hours |
| **Critical** | oauth2-proxy auth (requires reverse proxy pattern), regex rewrites, server snippets. | 2-4 hours |

### Step 5: Check for Known Gotchas

Run through this checklist of known migration pitfalls:

| # | Gotcha | Check | Impact |
|---|--------|-------|--------|
| 1 | Underscore headers | Does the app receive headers with underscores? | 400 errors without ClientTrafficPolicy fix |
| 2 | oauth2-proxy extAuth | Are `auth-url`/`auth-signin` annotations present? | Login completely broken if using SecurityPolicy extAuth |
| 3 | Session affinity CRD | Is `affinity: cookie` annotation present? | Must use `consistentHash.cookie`, NOT `sessionPersistence` |
| 4 | Body size CRD | Is `proxy-body-size` annotation present? | Must use BTP `requestBuffer.limit`, NOT CTP `clientRequestBody` |
| 5 | Bcrypt htpasswd | Is basic auth used? | Envoy only supports SHA hash, not bcrypt |
| 6 | Shared hostname | Does another Ingress share this hostname? | Must migrate together to avoid DNS flapping |
| 7 | Server snippets | Are `server-snippet` or `configuration-snippet` used? | No Envoy equivalent -- needs alternative approach |
| 8 | CDN-proxied | Is `config.dns.proxied` true? | Underscore header risk increases, TLS settings may interact |
| 9 | DR cluster | Does a standby/DR cluster share this hostname? | Must update DR values after primary migration |
| 10 | Regex rewrite | Is `rewrite-target` with regex used? | Envoy uses RE2 regex, not PCRE -- test carefully |

### Step 6: Produce Migration Complexity Report

Output the final report in this format:

```
=== Ingress Migration Analysis ===

App:        <name>
Namespace:  <namespace>
Hostname:   <hostname>
Complexity: <Simple|Medium|Complex|Critical>

--- Annotations Analysis ---

| # | Annotation | Value | Envoy Resource | Envoy Field | Status |
|---|-----------|-------|----------------|-------------|--------|
| 1 | ... | ... | HTTPRoute / BTP / SecurityPolicy | spec.field | Mapped / No equivalent / Warning |

--- Required Resources ---

1. HTTPRoute (required)
   - parentRefs: <gateway-name> in <namespace>
   - hostnames: [<hostname>]
   - rules: <path-count> path rules

2. BackendTrafficPolicy (if needed)
   - timeout: <value>
   - requestBuffer: <value>
   - loadBalancer: <affinity-config>

3. SecurityPolicy (if needed)
   - type: basicAuth
   - users secret: <secret-name>

--- Known Gotchas ---

| # | Gotcha | Applies? | Action Required |
|---|--------|----------|----------------|
| 1 | Underscore headers | Yes/No | Ensure ClientTrafficPolicy exists |
| ... | ... | ... | ... |

--- Recommendations ---

1. <Specific recommendation based on analysis>
2. <Specific recommendation based on analysis>
```

## Usage Notes

- This skill is analysis-only. It does NOT make any changes.
- Run this before `/migrate-app` to understand what is needed.
- The output can be fed directly into the `migration-planner` agent for plan generation.
- For batch analysis of all Ingresses on a cluster, use the `cluster-auditor` agent instead.

## References

- `docs/gotchas.md` -- Full gotcha list with debugging guides
- `docs/envoy-gateway-v1.7-crd-reference.md` -- CRD field details
- `docs/auth-migration-patterns.md` -- Auth pattern details
- `examples/httproute/` -- Example YAML for each complexity level
- CLAUDE.md constraints: 5, 7, 8, 13, 14, 16, 17
