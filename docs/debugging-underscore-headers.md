# Debugging Underscore Header Rejections

A step-by-step methodology for investigating HTTP 400 errors that appear only
when traffic arrives through a CDN or API gateway proxy, but work fine with
direct requests.

## The Scenario

You migrate an application from ingress-nginx to Envoy Gateway. Direct `curl`
requests to the backend work. Traffic through your CDN/proxy (Cloudflare,
AWS CloudFront, Azure Front Door, etc.) returns HTTP 400 with no useful error
message in the response body.

## Step 1: Identify Affected Traffic Pattern

Determine which requests fail:

```bash
# Direct to Envoy LB - works
curl -v https://app.example.com --resolve app.example.com:443:<ENVOY_LB_IP>

# Through CDN - returns 400
curl -v https://app.example.com
```

If direct requests succeed but CDN-proxied requests fail, the issue is in
headers added or forwarded by the CDN.

## Step 2: Compare Request Headers

Capture the full request headers that reach Envoy. CDN proxies often add or
forward headers with underscores:

- `X_Forwarded_For` (some legacy proxies)
- `X_Request_ID`
- Custom headers from webhook sources (e.g., `X_Hook_Secret`)
- Headers injected by third-party API gateways

## Step 3: Check Envoy Access Logs (Without RESPONSE_CODE_DETAILS)

If your access log format does not include `%RESPONSE_CODE_DETAILS%`, you will
see something unhelpful like:

```
[2024-01-15T10:23:45.000Z] "POST /api/webhook HTTP/1.1" 400 - 0 11 0 "-" "CDN-Agent/1.0" "-"
```

The `400` tells you nothing about why Envoy rejected it.

## Step 4: Add %RESPONSE_CODE_DETAILS% to Access Logs

Update your EnvoyProxy configuration to include this field:

```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: EnvoyProxy
metadata:
  name: custom-proxy
  namespace: envoy-gateway-system
spec:
  telemetry:
    accessLog:
      settings:
        - format:
            type: Text
            text: >-
              [%START_TIME%] "%REQ(:METHOD)% %REQ(X-ENVOY-ORIGINAL-PATH?:PATH)%
              %PROTOCOL%" %RESPONSE_CODE% %RESPONSE_CODE_DETAILS%
              %RESPONSE_FLAGS% %BYTES_RECEIVED% %BYTES_SENT% %DURATION%
              "%UPSTREAM_HOST%"
```

Now the logs reveal the root cause:

```
[2024-01-15T10:23:45.000Z] "POST /api/webhook HTTP/1.1" 400 http1.unexpected_underscore - 0 11 0 "-"
```

The value `http1.unexpected_underscore` tells you exactly what happened.

## Step 5: Apply the Fix

Create a `ClientTrafficPolicy` that allows underscored headers on the Gateway:

```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: ClientTrafficPolicy
metadata:
  name: allow-underscore-headers
  namespace: envoy-gateway-system
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: my-gateway
  headers:
    withUnderscoresAction: Allow
```

Apply and verify:

```bash
kubectl apply -f allow-underscore-headers.yaml
# Wait for reconciliation, then test
curl -v https://app.example.com
```

## Step 6: Verify and Prevent

Confirm the fix by re-testing the CDN-proxied path. Then add the
`ClientTrafficPolicy` to your cluster bootstrap automation so every new cluster
gets it from day zero.

## Why ingress-nginx Did Not Have This Problem

ingress-nginx (and nginx in general) allows underscores in headers by default
via the `underscores_in_headers on` directive. Envoy takes the opposite default
for security reasons -- underscored headers can sometimes be used in header
injection attacks. For most production environments behind a trusted CDN, the
safe choice is to allow them.

## Key Takeaway

Always include `%RESPONSE_CODE_DETAILS%` in your Envoy access log format. It is
the single most important debugging field and reveals issues that are otherwise
invisible.
