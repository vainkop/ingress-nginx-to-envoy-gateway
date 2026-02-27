# DNS Cutover Strategy

Moving DNS from the ingress-nginx LoadBalancer IP to the Envoy Gateway
LoadBalancer IP is the most critical and irreversible step of each app
migration. This document covers the rules, risks, and rollback procedures.

## Atomic Cutover Rule

The cutover for each hostname MUST be atomic: disable the Ingress resource and
enable the HTTPRoute in a **single commit**. Never have both active for the same
hostname simultaneously.

```yaml
# In a SINGLE commit / values change:
ingress:
  enabled: false        # Removes the Ingress resource
gatewayAPI:
  enabled: true         # Creates the HTTPRoute
```

### Why Atomic?

If both an Ingress and an HTTPRoute exist for the same hostname at the same
time, external-dns discovers two sources of truth. On each reconciliation loop
it alternates the DNS A record between the nginx LB IP and the Envoy LB IP.
This causes intermittent failures as traffic randomly hits the wrong controller.

## Pre-Cutover Checklist

1. HTTPRoute template is tested with `helm template` and passes validation
2. TLS secret is copied to `envoy-gateway-system` namespace (see
   [cert-manager-gateway-setup.md](cert-manager-gateway-setup.md))
3. BackendTrafficPolicy is ready (if app needs timeouts, body limits, etc.)
4. The Gateway listener for the hostname's port is configured with
   `allowedRoutes.namespaces.from: All`
5. Application pods are healthy

## external-dns Dual-Source Problem

external-dns watches both Ingress and HTTPRoute (or Gateway) resources for DNS
record sources. When both exist for the same hostname:

- **Sync mode**: external-dns may delete one record to create the other,
  causing a brief outage.
- **Upsert-only mode**: external-dns creates/updates but never deletes. Both
  controllers try to upsert their own IP, causing flapping.

Either mode is problematic with dual resources. The atomic cutover avoids this
entirely.

## DNS Provider Notes

### Cloudflare (Proxied Mode)

When DNS records are proxied through Cloudflare, the end-user-visible IP is a
Cloudflare edge IP, not your origin LB IP. This means:

- Origin IP changes are **transparent to end users** (no visible DNS
  propagation delay).
- However, Cloudflare must be able to reach your new origin (Envoy LB).
  Verify the origin is reachable before switching.
- SSL mode matters: if the zone uses "Flexible" SSL, Cloudflare connects to
  origin on port 80. If "Full" or "Full (Strict)", it connects on 443 and
  validates the cert. Check Configuration Rules as they can override zone-level
  SSL settings.

### Route53 / Cloud DNS

For non-proxied DNS providers:

- TTL determines how long clients cache the old IP. Lower the TTL to 60s
  before the cutover window, then restore it afterward.
- Use `dig` or `nslookup` to verify propagation.

## upsert-only vs sync Policy

| Policy | Behavior | Implication |
|--------|----------|-------------|
| `upsert-only` | Creates and updates records, never deletes | Old A records pointing to nginx LB remain after Ingress is deleted. Manual cleanup required. |
| `sync` | Full lifecycle: create, update, delete | Old records auto-delete when the Ingress is removed. But dual-source flapping is worse during overlap. |

### Stale Record Cleanup (upsert-only)

After cutover with `upsert-only`, manually remove stale DNS records:

```bash
# List records for the hostname
# (Use your DNS provider's CLI or API)

# Cloudflare example:
curl -X GET "https://api.cloudflare.com/client/v4/zones/<ZONE_ID>/dns_records?name=app.example.com" \
  -H "Authorization: Bearer <TOKEN>"

# Delete the stale A record pointing to old nginx LB IP
curl -X DELETE "https://api.cloudflare.com/client/v4/zones/<ZONE_ID>/dns_records/<RECORD_ID>" \
  -H "Authorization: Bearer <TOKEN>"
```

## Rollback Procedure

If the cutover fails and you need to revert:

1. **Revert the commit**: Set `ingress.enabled: true` and
   `gatewayAPI.enabled: false`.
2. **Wait for reconciliation**: The GitOps controller recreates the Ingress
   and removes the HTTPRoute.
3. **Verify DNS**: Confirm external-dns updates the record back to the nginx
   LB IP.
4. **Check TLS**: The original cert-manager Certificate should still exist. If
   it was deleted, cert-manager will re-issue via the nginx-based ClusterIssuer.

### Rollback Timing

- With proxied DNS (Cloudflare): rollback is near-instant since the edge IP
  does not change.
- With direct DNS: rollback is limited by TTL. If TTL was lowered to 60s
  pre-cutover, recovery is fast. If TTL is the default (300s+), clients may
  cache the stale IP for several minutes.

## Post-Cutover Verification

```bash
# Confirm only HTTPRoute exists (no Ingress)
kubectl get ingress -A | grep app.example.com   # Should return nothing
kubectl get httproute -A | grep app.example.com  # Should show the route

# Confirm DNS resolves to Envoy LB
dig +short app.example.com

# Confirm TLS is valid
curl -vI https://app.example.com 2>&1 | grep "SSL certificate"

# Confirm app responds correctly
curl -s -o /dev/null -w "%{http_code}" https://app.example.com/healthz
```
