# Validation Test Commands Reference

## Get Envoy Gateway LB IP
```bash
kubectl get svc -n envoy-gateway-system \
  -l gateway.envoyproxy.io/owning-gateway-name=envoy-gateway \
  -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}'
```

Store it for reuse:
```bash
ENVOY_IP=$(kubectl get svc -n envoy-gateway-system \
  -l gateway.envoyproxy.io/owning-gateway-name=envoy-gateway \
  -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}')
echo "Envoy LB IP: ${ENVOY_IP}"
```

## Test via Envoy Gateway Directly (Bypassing DNS)
```bash
curl -sv --resolve "<hostname>:443:${ENVOY_IP}" "https://<hostname>/"
```
The `--resolve` flag overrides DNS so you can test routing through Envoy before switching DNS.

## Check HTTPRoute Status
```bash
# List all HTTPRoutes across namespaces
kubectl get httproute -A

# Check a specific HTTPRoute's conditions
kubectl get httproute <app-name> -n <namespace> -o jsonpath='{.status.parents[0].conditions[*].type}'
# Expected output: Accepted ResolvedRefs

# Detailed status with reason codes
kubectl get httproute <app-name> -n <namespace> -o json | \
  jq '.status.parents[0].conditions[] | {type, status, reason, message}'
```

## Check Policy Status
```bash
# List all BackendTrafficPolicies
kubectl get backendtrafficpolicy -A

# Check a specific BTP's status
kubectl get backendtrafficpolicy <app-name>-btp -n <namespace> -o json | \
  jq '.status.conditions[] | {type, status, reason}'
# Expected: Accepted: True

# List all SecurityPolicies
kubectl get securitypolicy -A

# List all ClientTrafficPolicies
kubectl get clienttrafficpolicy -A
```

## Check cert-manager Certificates
```bash
# Check if certificate exists in the gateway namespace
kubectl get certificate -n envoy-gateway-system | grep <hostname>

# Verify certificate dates
kubectl get secret <hostname>-tls -n envoy-gateway-system \
  -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -dates

# Check certificate status
kubectl get certificate -n envoy-gateway-system -o json | \
  jq '.items[] | select(.metadata.name | contains("<hostname>")) | {name: .metadata.name, ready: .status.conditions[0].status}'
```

## WebSocket Test
```bash
# Using curl (checks upgrade response headers)
curl -sI \
  --resolve "<hostname>:443:${ENVOY_IP}" \
  -H "Upgrade: websocket" \
  -H "Connection: Upgrade" \
  -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
  -H "Sec-WebSocket-Version: 13" \
  "https://<hostname>/ws"
# Expected: HTTP/1.1 101 Switching Protocols

# Using websocat (full connection test, install via cargo or package manager)
websocat "wss://<hostname>/ws"
```

## Session Affinity Test
```bash
# First request - get cookie
curl -sv --resolve "<hostname>:443:${ENVOY_IP}" \
  "https://<hostname>/" 2>&1 | grep -i set-cookie
# Expected: set-cookie: <cookie-name>=<hash>; ...

# Subsequent requests with cookie - verify same backend
for i in $(seq 1 5); do
  curl -s --resolve "<hostname>:443:${ENVOY_IP}" \
    -b "<cookie-name>=<cookie-value>" \
    "https://<hostname>/health" -o /dev/null -w "%{response_code}\n"
done
```

## DNS Check
```bash
# Resolve hostname (should return CDN/proxy IPs if proxied, or LB IP if direct)
dig +short <hostname>

# Check origin IP via DNS provider API (example: Cloudflare)
curl -s "https://api.cloudflare.com/client/v4/zones/<zone-id>/dns_records?name=<hostname>" \
  -H "Authorization: Bearer <api-token>" | jq '.result[] | {name, content, type}'

# Verify the origin record points to Envoy LB IP (not nginx)
# The "content" field should match ${ENVOY_IP}
```

## Compare Response Headers (nginx vs Envoy)
```bash
# Get nginx LB IP
NGINX_IP=$(kubectl get svc -n ingress-nginx \
  -l app.kubernetes.io/name=ingress-nginx \
  -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}')

# Test through nginx
curl -sI --resolve "<hostname>:443:${NGINX_IP}" "https://<hostname>/" | grep -i server
# Expected: server: nginx

# Test through envoy
curl -sI --resolve "<hostname>:443:${ENVOY_IP}" "https://<hostname>/" | grep -i server
# Expected: server: envoy
```

## Check for Remaining nginx References
```bash
# List all remaining Ingress resources
kubectl get ingress -A

# Filter to only nginx-class Ingresses
kubectl get ingress -A -o json | \
  jq '.items[] | select(.spec.ingressClassName == "nginx") | {name: .metadata.name, namespace: .metadata.namespace}'

# Count remaining nginx Ingresses
kubectl get ingress -A -o json | \
  jq '[.items[] | select(.spec.ingressClassName == "nginx")] | length'
```

## Basic Auth Validation
```bash
# Test without credentials (should return 401)
curl -sv --resolve "<hostname>:443:${ENVOY_IP}" "https://<hostname>/" 2>&1 | grep "< HTTP"
# Expected: HTTP/2 401

# Test with valid credentials (should return 200)
curl -sv --resolve "<hostname>:443:${ENVOY_IP}" \
  -u "<username>:<password>" "https://<hostname>/" 2>&1 | grep "< HTTP"
# Expected: HTTP/2 200
```

## oauth2-proxy (Reverse Proxy Pattern) Validation
```bash
# Test unauthenticated (should redirect to login)
curl -sv --resolve "<hostname>:443:${ENVOY_IP}" \
  "https://<hostname>/" 2>&1 | grep -i location
# Expected: Location header pointing to OAuth provider login page

# Verify oauth2-proxy pod is running
kubectl get pods -n <namespace> -l app=oauth2-proxy
```
