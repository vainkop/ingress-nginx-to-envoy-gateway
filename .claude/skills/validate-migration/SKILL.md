---
name: validate-migration
description: >
  Validates that a migrated application works correctly through Envoy Gateway.
  Runs a 10-step checklist covering routing, TLS, DNS, WebSocket, affinity, and observability.
  Use when "validate X", "check migration for X", "verify X works on envoy".
license: Apache-2.0
metadata:
  author: vainkop
  version: 1.0.0
  tags: [validation, post-migration, checklist]
---

# Validate a Migrated Application

This skill runs a comprehensive post-migration validation checklist for a single application.
It verifies that the HTTPRoute is functioning correctly, TLS is working, DNS is resolved
to the Envoy LoadBalancer, and all application-specific features (WebSocket, session
affinity, auth) are intact.

## Prerequisites

- `migration.config.yaml` populated for the target cluster
- The app has been migrated (HTTPRoute exists, Ingress removed)
- `kubectl` access to the cluster
- `curl` available for HTTP checks

## Procedure

### Step 1: Identify the Application

Gather from the user or from `migration.config.yaml`:
- App name
- Namespace
- Expected hostname(s)
- Expected path(s)
- Whether auth is in front of the app (oauth2-proxy or basic auth)
- Whether WebSocket or session affinity is used

### Step 2: Gather Expected State from Values

Read the env-specific values file to determine:
- `gatewayAPI.enabled` should be `true`
- `ingress.enabled` should be `false`
- Gateway name, namespace, and listener sectionName
- TLS issuer and Secret name
- Any BackendTrafficPolicy settings (timeout, body size, affinity)

Confirm that `ingress.enabled: false` and `gatewayAPI.enabled: true` are both set.
If both are true or both are false, flag as a configuration error.

### Step 3: Check HTTPRoute Status

```bash
kubectl get httproute <name> -n <namespace> -o yaml
```

Verify the following status conditions:

| Condition | Expected | Meaning |
|-----------|----------|---------|
| `Accepted` | `True` | Gateway accepted the route |
| `ResolvedRefs` | `True` | Backend service references are valid |

If `Accepted` is `False`, check:
- Does the Gateway have a listener matching the HTTPRoute's hostname?
- Is `allowedRoutes.namespaces.from: All` set on the Gateway listener?
- Is the `parentRef` gateway name and namespace correct?

If `ResolvedRefs` is `False`, check:
- Does the backend Service exist?
- Is the port correct?
- Are there network policies blocking cross-namespace resolution?

### Step 4: Check TLS Certificate

```bash
# Check the certificate object
kubectl get certificate -n <namespace> -l <relevant-labels>

# Check the TLS secret
kubectl get secret <tls-secret-name> -n <gateway-namespace>

# Check certificate expiry via openssl
echo | openssl s_client -connect <hostname>:443 -servername <hostname> 2>/dev/null | \
  openssl x509 -noout -dates -subject
```

Verify:
- Certificate exists and is in `Ready: True` state
- TLS Secret exists in the Gateway namespace (`config.advanced.namespace`)
- Certificate subject matches the expected hostname
- Certificate is not expired and has reasonable remaining validity (>14 days)

### Step 5: Check HTTP Routing

```bash
# Direct request to the hostname
curl -sv https://<hostname>/ 2>&1

# Check response headers
curl -sI https://<hostname>/
```

Verify:
- HTTP status code is the expected value (200, 301, 302, etc.)
- Response does NOT contain `server: nginx` header (would indicate traffic still going to nginx)
- Response body or redirect matches expected application behavior
- No unexpected 400, 404, or 503 errors

If getting 400 errors:
- Check Envoy access logs for `%RESPONSE_CODE_DETAILS%`
- Common cause: missing ClientTrafficPolicy for underscore headers

If getting 404 errors:
- Check `%RESPONSE_CODE_DETAILS%` for `filter_chain_not_found` (means no Gateway listener matches)
- Verify the Gateway has a listener for this specific hostname

### Step 6: Check WebSocket Support (If Applicable)

WebSocket works by default through Envoy Gateway (no special annotation needed, unlike nginx).

```bash
# Test WebSocket upgrade (requires wscat or similar)
wscat -c wss://<hostname>/ws-path
```

Or verify with curl:
```bash
curl -sv -H "Upgrade: websocket" -H "Connection: Upgrade" \
  -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
  -H "Sec-WebSocket-Version: 13" \
  https://<hostname>/ws-path
```

Expected: HTTP 101 Switching Protocols response.

If WebSocket fails, check:
- BackendTrafficPolicy timeout is long enough (`spec.timeout.http.requestTimeout`)
- The backend service port is correct

### Step 7: Check Session Affinity (If Applicable)

If the app uses cookie-based session affinity (previously `nginx.ingress.kubernetes.io/affinity: cookie`):

```bash
# First request -- should set a cookie
curl -sv https://<hostname>/ 2>&1 | grep -i set-cookie

# Second request with cookie -- should hit the same backend
curl -sv -b "cookie-name=cookie-value" https://<hostname>/ 2>&1
```

Verify:
- A session cookie is set by Envoy
- Subsequent requests with the cookie reach the same backend pod
- BackendTrafficPolicy exists with `spec.loadBalancer.consistentHash.cookie` configured

### Step 8: Check DNS Resolution

```bash
# Resolve the hostname
dig +short <hostname>

# Or via nslookup
nslookup <hostname>
```

Verify:
- DNS resolves to the **Envoy** LoadBalancer IP, not the nginx LoadBalancer IP
- If `config.dns.proxied` is `true` (CDN-proxied), DNS will resolve to CDN IPs, not the LB directly.
  In this case, check external-dns logs or DNS provider dashboard to confirm the origin record
  points to the Envoy LB IP.

If DNS still points to the nginx LB IP:
- Check if external-dns has reconciled the HTTPRoute
- If `config.dns.external_dns_policy` is `upsert-only`, the old A record may persist.
  Manually update it in your DNS provider.
- Verify the old Ingress resource is fully deleted

### Step 9: Check Observability

Verify that the app's traffic is visible in the monitoring stack:

```bash
# Check Envoy proxy access logs
kubectl logs -n <config.advanced.namespace> -l gateway.envoyproxy.io/owning-gateway-name=<gateway-name> \
  --tail=50 | grep <hostname>
```

Verify:
- Access logs show requests to the app's hostname
- `%RESPONSE_CODE_DETAILS%` field is present in log lines (configured in EnvoyProxy telemetry)
- No unexpected error codes in the logs
- If observability tools are configured (`config.observability.tool`), verify the app appears
  in dashboards with correct RPS, latency, and error rate metrics

### Step 10: Generate Validation Report

Compile results into a summary table:

| # | Check | Status | Details |
|---|-------|--------|---------|
| 1 | App identified | PASS/FAIL | Name, namespace, hostname |
| 2 | Values configuration | PASS/FAIL | gatewayAPI.enabled=true, ingress.enabled=false |
| 3 | HTTPRoute status | PASS/FAIL | Accepted + ResolvedRefs conditions |
| 4 | TLS certificate | PASS/FAIL | Cert status, expiry, subject match |
| 5 | HTTP routing | PASS/FAIL | Status code, no nginx header, correct response |
| 6 | WebSocket | PASS/SKIP/FAIL | 101 upgrade or N/A |
| 7 | Session affinity | PASS/SKIP/FAIL | Cookie set and sticky or N/A |
| 8 | DNS resolution | PASS/FAIL | Points to Envoy LB IP |
| 9 | Observability | PASS/WARN/FAIL | Logs visible, metrics flowing |
| 10 | **Overall** | **PASS/FAIL** | All critical checks passed |

**Overall result:**
- **PASS**: All checks passed (SKIP counts as pass for non-applicable features)
- **FAIL**: Any check failed -- list the failed checks and remediation steps

## Remediation Quick Reference

| Symptom | Likely Cause | Fix |
|---------|-------------|-----|
| HTTPRoute not Accepted | Missing Gateway listener or wrong `allowedRoutes` | Add listener with `from: All` |
| 400 errors | Underscore headers rejected | Apply ClientTrafficPolicy `withUnderscoresAction: Allow` |
| 404 errors | `filter_chain_not_found` | Add Gateway listener for hostname |
| 503 errors | Backend service unreachable | Check Service exists and port is correct |
| TLS errors | Secret not in Gateway namespace | Copy Secret to `config.advanced.namespace` |
| DNS wrong IP | Old nginx record persists | Manually update DNS if `upsert-only` policy |
| oauth2-proxy login broken | Used SecurityPolicy extAuth | Switch to reverse proxy pattern |
| No session stickiness | Wrong BTP field | Use `loadBalancer.consistentHash.cookie`, not `sessionPersistence` |

## References

- `docs/gotchas.md` -- Known failure modes
- `docs/debugging-underscore-headers.md` -- 400 error debugging
- `docs/dns-cutover-strategy.md` -- DNS verification steps
- `docs/auth-migration-patterns.md` -- Auth validation specifics
- CLAUDE.md constraints: 5, 8, 12, 13, 14, 15, 16, 17
