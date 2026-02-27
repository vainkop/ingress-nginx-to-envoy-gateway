# Gotchas: ingress-nginx to Envoy Gateway Migration

Hard-won lessons from production migrations. Each gotcha includes the symptom you
will see, the root cause, the fix, and how to prevent it from biting future
clusters.

---

## 1. Envoy Rejects Headers With Underscores

**Symptom:** Requests arriving through a CDN or API gateway return HTTP 400 at
the Envoy proxy layer. Direct pod-to-pod requests work fine. Affected traffic
often includes third-party webhook callbacks or server-side callouts that set
custom headers containing underscores (e.g. `X_Custom_Token`).

**Root Cause:** Envoy's default HTTP/1.1 codec rejects any header whose name
contains an underscore character. ingress-nginx (and most other reverse proxies)
allow underscores by default. When a CDN like Cloudflare forwards the original
request headers unchanged, Envoy drops the connection before the request reaches
the backend.

**Fix:** Apply a `ClientTrafficPolicy` on every Gateway that allows underscored
headers:

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

**Prevention:** Include this policy in your base cluster setup automation. Treat
it as a day-zero requirement, not a per-app opt-in.

---

## 2. Gateway allowedRoutes Defaults to `from: Same`

**Symptom:** HTTPRoutes in application namespaces are created but never attach to
the Gateway. `kubectl get httproute -A` shows `Accepted: False` with reason
`NotAllowedByListeners`.

**Root Cause:** The Gateway API spec defaults `listeners[].allowedRoutes.namespaces.from`
to `Same`, meaning only HTTPRoutes in the Gateway's own namespace (typically
`envoy-gateway-system`) can attach. Application HTTPRoutes live in their own
namespaces.

**Fix:** Set `allowedRoutes` on every listener:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: my-gateway
  namespace: envoy-gateway-system
spec:
  listeners:
    - name: https
      port: 443
      protocol: HTTPS
      allowedRoutes:
        namespaces:
          from: All
```

**Prevention:** Validate with `kubectl get gateway -o yaml` after initial
deployment. Check that every listener has `from: All` (or an explicit selector).

---

## 3. BackendTrafficPolicy.spec.sessionPersistence Does Not Exist

**Symptom:** `kubectl apply` fails with a validation error or the field is
silently ignored. Pods do not receive sticky sessions.

**Root Cause:** As of Envoy Gateway v1.7.0, `BackendTrafficPolicy` does not
have a top-level `spec.sessionPersistence` field. The session affinity
configuration lives under `spec.loadBalancer.consistentHash`.

**Fix:** Use the correct path:

```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: BackendTrafficPolicy
metadata:
  name: sticky-sessions
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: my-route
  loadBalancer:
    type: ConsistentHash
    consistentHash:
      type: Cookie
      cookie:
        name: SESSION_AFFINITY
        ttl: 3600s
```

**Prevention:** Always cross-reference the CRD schema for your installed version
before writing policy manifests. See
[docs/envoy-gateway-v1.7-crd-reference.md](envoy-gateway-v1.7-crd-reference.md).

---

## 4. cert-manager featureGates Deprecated for Gateway API

**Symptom:** cert-manager does not watch Gateway or HTTPRoute resources. Certificates
referencing a Gateway issuer are never issued. The cert-manager controller logs
show no Gateway-related activity.

**Root Cause:** The old `--feature-gates=ExperimentalGatewayAPISupport=true` flag
was deprecated. cert-manager now uses a Helm values key.

**Fix:** In your cert-manager Helm values:

```yaml
config:
  enableGatewayAPI: true
```

After upgrading the Helm release, restart the cert-manager controller pod so it
picks up the new RBAC rules for Gateway API resources:

```bash
kubectl rollout restart deployment cert-manager -n cert-manager
```

**Prevention:** Include `enableGatewayAPI: true` in your cert-manager base values
and verify with `kubectl logs deploy/cert-manager -n cert-manager | grep -i gateway`.

---

## 5. SecurityPolicy extAuth Strips Location Headers (Breaks OIDC Redirects)

**Symptom:** Browser-based login with oauth2-proxy never completes. The user
clicks "login" but gets a blank page or a generic error instead of being
redirected to the identity provider. Direct API calls to the auth endpoint work.

**Root Cause:** Envoy's `ext_authz` filter does not forward the `Location` header
from the external authorization response back to the client when the auth service
returns a 302 redirect. oauth2-proxy relies on 302 redirects to send users to the
IdP and back. Without the `Location` header, the browser has nowhere to go.

**Fix:** Do NOT use `SecurityPolicy` with `extAuth` for oauth2-proxy. Instead,
route all traffic through oauth2-proxy as a reverse proxy. oauth2-proxy handles
authentication and then forwards authenticated requests to the upstream app via
`OAUTH2_PROXY_UPSTREAMS`.

See [docs/auth-migration-patterns.md](auth-migration-patterns.md) for the
recommended architecture.

**Prevention:** Reserve `extAuth` for non-redirect auth patterns (API keys, JWT
validation, machine-to-machine tokens). For any browser-based OIDC/OAuth2 flow,
use the reverse proxy pattern.

---

## 6. TLS Certificate Chicken-and-Egg Problem

**Symptom:** After creating an HTTPRoute with a new TLS certificate request,
cert-manager's http01 challenge fails because DNS still points to the old
ingress-nginx LoadBalancer. The certificate stays in a `Pending` state
indefinitely.

**Root Cause:** cert-manager's http01 solver needs to receive the ACME challenge
request on the new Envoy Gateway, but DNS has not been switched yet (and you
cannot switch DNS without a valid certificate).

**Fix:** Copy the existing TLS secret from the application namespace into the
`envoy-gateway-system` namespace before the DNS cutover:

```bash
kubectl get secret my-app-tls -n my-app -o yaml \
  | sed 's/namespace: my-app/namespace: envoy-gateway-system/' \
  | kubectl apply -f -
```

After DNS switches to the Envoy LB IP, cert-manager will be able to complete
http01 challenges and will auto-renew the certificate normally.

**Prevention:** Include the secret copy step in your migration runbook as a
pre-cutover task. Verify the secret exists in `envoy-gateway-system` before
proceeding with DNS changes.

---

## 7. DNS Flapping From Dual Ingress + HTTPRoute

**Symptom:** The application intermittently resolves to the old nginx LB IP and
the new Envoy LB IP. Users experience random failures as some requests hit the
wrong controller (which may not have a valid backend or TLS certificate).

**Root Cause:** If both an Ingress resource and an HTTPRoute exist for the same
hostname simultaneously, external-dns sees two sources of truth and alternates
the DNS A record between the two LoadBalancer IPs on each reconciliation loop.

**Fix:** The DNS cutover must be atomic per hostname. In a single commit:

1. Set `ingress.enabled: false` (removes the Ingress resource)
2. Set `gatewayAPI.enabled: true` (creates the HTTPRoute)

Never have both active for the same hostname at the same time.

**Prevention:** Use a single commit/PR for the cutover. Validate with
`kubectl get ingress,httproute -A | grep <hostname>` to confirm only one
resource type exists for each hostname.

---

## 8. requestBuffer.limit Wrong Units

**Symptom:** BackendTrafficPolicy is rejected or the request body size limit does
not behave as expected (e.g., a 10 MB limit is interpreted as 10 millibytes).

**Root Cause:** The `requestBuffer.limit` field uses Kubernetes `resource.Quantity`
format. The correct suffixes are `Mi` (mebibytes) and `Gi` (gibibytes). Lowercase
`m` means "milli" (1/1000), not "mega".

**Fix:**

```yaml
# Correct - 10 mebibytes
spec:
  requestBuffer:
    limit: "10Mi"

# WRONG - 10 milli (essentially zero)
spec:
  requestBuffer:
    limit: "10m"
```

**Prevention:** Always use uppercase `Mi` or `Gi` for size limits. Validate by
checking the applied policy: `kubectl get backendtrafficpolicy -o yaml`.

---

## 9. ClientTrafficPolicy.spec.clientRequestBody Does Not Exist

**Symptom:** Attempting to set a client request body size limit via
`ClientTrafficPolicy` fails validation or is silently ignored.

**Root Cause:** As of Envoy Gateway v1.7.0, there is no
`spec.clientRequestBody` field on `ClientTrafficPolicy`. Request body size
limiting is done through `BackendTrafficPolicy.spec.requestBuffer.limit`.

**Fix:**

```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: BackendTrafficPolicy
metadata:
  name: body-limit
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: my-route
  requestBuffer:
    limit: "10Mi"
```

**Prevention:** Check the CRD reference before assuming field locations. The
split between ClientTrafficPolicy (client-facing settings) and
BackendTrafficPolicy (upstream-facing settings) is not always intuitive.

---

## 10. GatewayClass controllerName Mismatch

**Symptom:** The Gateway resource stays in `Pending` state. No Envoy proxy pods
are created. The GatewayClass shows `Accepted: False`.

**Root Cause:** The `controllerName` in the GatewayClass must exactly match what
the Envoy Gateway controller is registered as. The Helm chart may use a different
value than what the upstream documentation shows.

**Fix:** Check what the Helm chart installs:

```bash
kubectl get gatewayclass -o yaml
```

The standard controllerName for Envoy Gateway is:

```
gateway.envoyproxy.io/gatewayclass-controller
```

Ensure your GatewayClass matches:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: envoy-gateway
spec:
  controllerName: gateway.envoyproxy.io/gatewayclass-controller
```

**Prevention:** Let the Helm chart create the GatewayClass. If you need a custom
one, extract the controllerName from the installed chart first.

---

## 11. GatewayClass controllerName Is Immutable

**Symptom:** `kubectl apply` on a GatewayClass with a corrected `controllerName`
fails with an immutability error.

**Root Cause:** The `controllerName` field on GatewayClass is immutable after
creation. You cannot update it in place.

**Fix:** Delete and recreate the GatewayClass:

```bash
kubectl delete gatewayclass envoy-gateway
kubectl apply -f gatewayclass.yaml
```

Note: this will temporarily disrupt all Gateways referencing this class.

**Prevention:** Get the controllerName right on first creation. Verify with
`kubectl get gatewayclass -o jsonpath='{.items[*].spec.controllerName}'` before
creating any Gateway resources.

---

## 12. HPA Overrides replicaCount During Decommission

**Symptom:** You scale ingress-nginx down to 0 replicas, but the pods keep
coming back. The deployment never reaches 0.

**Root Cause:** If a HorizontalPodAutoscaler (HPA) exists for the ingress-nginx
controller, it overrides the `replicaCount` in the Helm values. The HPA has a
`minReplicas` floor (often 2 or 3) and will scale the deployment back up.

**Fix:** Disable the HPA before scaling down:

```yaml
# In ingress-nginx Helm values
controller:
  autoscaling:
    enabled: false
  replicaCount: 0
```

Or delete the HPA directly:

```bash
kubectl delete hpa ingress-nginx-controller -n ingress-nginx
```

Then set `replicaCount: 0`.

**Prevention:** Include HPA removal as the first step in your decommission
runbook. See [docs/decommission-nginx.md](decommission-nginx.md).

---

## 13. web-values.yaml Overrides ingress.enabled for Library Charts

**Symptom:** You set `gatewayAPI.enabled: true` and `ingress.enabled: false` in
the environment-specific values file, but the Ingress resource is still created.

**Root Cause:** Helm values files are merged in order. If your chart uses a
multi-file values strategy like:

```
values.yaml -> web-values.yaml -> env-values.yaml
```

And `web-values.yaml` has `ingress.enabled: true`, it may be loaded after (or
merged with) your environment override depending on the values file ordering in
your HelmRelease or ArgoCD Application spec.

**Fix:** Create an explicit override values file that is loaded last and takes
precedence:

```yaml
# web-env-override-values.yaml (loaded last)
ingress:
  enabled: false
gatewayAPI:
  enabled: true
```

Ensure this file appears last in the `valuesFiles` list.

**Prevention:** Audit the values file merge order for every app before migration.
Use `helm template` with all values files to verify the final merged output.

---

## 14. Orphaned Helm Releases After GitOps Adoption

**Symptom:** After migrating an app from CI/CD-deployed Helm releases to GitOps
(ArgoCD or Flux), stale Helm release secrets remain in the namespace. These can
cause confusion and may interfere with rollbacks.

**Root Cause:** When a CI/CD pipeline (e.g., GitHub Actions) runs `helm upgrade
--install` and you later adopt the app into a GitOps tool, the old Helm release
metadata (stored as Kubernetes Secrets with type `helm.sh/release.v1`) is not
automatically cleaned up.

**Fix:** After confirming the GitOps-managed release is healthy:

```bash
# List orphaned Helm releases
kubectl get secrets -n my-app -l owner=helm,status=deployed

# Delete old release secrets (careful - verify first)
kubectl delete secret -n my-app -l owner=helm,name=old-release-name
```

Also remove any manually created Ingress resources that were not part of the
Helm chart:

```bash
kubectl get ingress -n my-app
kubectl delete ingress manual-ingress -n my-app
```

**Prevention:** Document which apps are CI/CD-deployed vs. GitOps-managed. Plan
the adoption step explicitly and include cleanup in the runbook.

---

## 15. Access Log Missing %RESPONSE_CODE_DETAILS% Makes Debugging Impossible

**Symptom:** Envoy returns 400 or 503 errors but the access logs only show the
status code. You cannot determine whether the error is from the backend, a
policy, a header validation failure, or a TLS issue.

**Root Cause:** The default Envoy access log format does not include the
`%RESPONSE_CODE_DETAILS%` field, which contains the specific reason Envoy
generated or forwarded the error (e.g., `http1.unexpected_underscore`,
`filter_chain_not_found`, `upstream_reset_before_response_started`).

**Fix:** Add `%RESPONSE_CODE_DETAILS%` to the EnvoyProxy telemetry config:

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
              %RESPONSE_FLAGS% %BYTES_RECEIVED% %BYTES_SENT%
              %DURATION% "%REQ(X-FORWARDED-FOR)%" "%REQ(USER-AGENT)%"
              "%UPSTREAM_HOST%"
```

Reference this EnvoyProxy from your GatewayClass `parametersRef`.

**Prevention:** Include `%RESPONSE_CODE_DETAILS%` in your access log format from
day zero. This single field saves hours of debugging time.

---

## 16. SecurityPolicy basicAuth Requires SHA Hash (Not bcrypt)

**Symptom:** `SecurityPolicy` with `basicAuth` is applied but all requests
return 401 Unauthorized, even with correct credentials.

**Root Cause:** Envoy's basic auth filter expects `.htpasswd` entries using SHA1
hash format. bcrypt (`$2y$` prefix) is the default for the `htpasswd` CLI tool
but is not supported by Envoy.

**Fix:** Generate the `.htpasswd` file with SHA hash:

```bash
htpasswd -s -nb myuser mypassword
# Output: myuser:{SHA}W6ph5Mm5Pz8GgiULbPgzG37mj9g=
```

Create the Secret with a `.htpasswd` key:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: basic-auth
  namespace: my-app
type: Opaque
stringData:
  .htpasswd: |
    myuser:{SHA}W6ph5Mm5Pz8GgiULbPgzG37mj9g=
```

Reference it in the SecurityPolicy:

```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: SecurityPolicy
metadata:
  name: basic-auth-policy
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: my-route
  basicAuth:
    users:
      name: basic-auth
```

**Prevention:** Always use `-s` flag with htpasswd. Validate the hash prefix is
`{SHA}` not `$2y$` before applying.

---

## 17. targetRef vs targetRefs Deprecation

**Symptom:** SecurityPolicy or other policy resources show warnings about
deprecated fields, or fail validation in newer CRD versions.

**Root Cause:** The Gateway API policy attachment model originally used a singular
`targetRef` field. This has been deprecated in favor of the plural `targetRefs`
(a list), which allows a single policy to target multiple resources. Similarly,
HTTPRoute uses `backendRefs` (plural) not `backendRef`.

**Fix:** Always use the plural form:

```yaml
# Correct
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: my-route

# Deprecated - may stop working in future versions
spec:
  targetRef:
    group: gateway.networking.k8s.io
    kind: HTTPRoute
    name: my-route
```

**Prevention:** Search your manifests for `targetRef:` (without the 's') and
update them. Set up a CI lint step that flags the deprecated singular form.

---

## Summary Table

| # | Gotcha | Severity | When You Hit It |
|---|--------|----------|-----------------|
| 1 | Underscore headers rejected | Critical | First CDN-proxied traffic |
| 2 | allowedRoutes from: Same | Critical | First cross-namespace HTTPRoute |
| 3 | sessionPersistence wrong path | Medium | Sticky session config |
| 4 | featureGates deprecated | Medium | cert-manager setup |
| 5 | extAuth strips Location | Critical | oauth2-proxy migration |
| 6 | TLS chicken-and-egg | High | DNS cutover |
| 7 | DNS flapping dual resources | Critical | Cutover window |
| 8 | requestBuffer wrong units | Medium | Body size limits |
| 9 | clientRequestBody wrong CRD | Medium | Body size limits |
| 10 | controllerName mismatch | High | Initial Gateway setup |
| 11 | controllerName immutable | Medium | Fixing setup mistakes |
| 12 | HPA overrides replicaCount | Medium | nginx decommission |
| 13 | web-values.yaml override | Medium | Library chart migration |
| 14 | Orphaned Helm releases | Low | GitOps adoption |
| 15 | Missing RESPONSE_CODE_DETAILS | High | Any proxy-level error |
| 16 | basicAuth needs SHA not bcrypt | Medium | Basic auth setup |
| 17 | targetRef deprecated | Low | Policy creation |
