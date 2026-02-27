# cert-manager Setup for Gateway API

cert-manager can issue TLS certificates for Gateway API resources, but it
requires specific configuration that differs from the traditional Ingress-based
setup.

## Step 1: Enable Gateway API Support in cert-manager

In your cert-manager Helm values, use the `config.enableGatewayAPI` key:

```yaml
# cert-manager Helm values
config:
  enableGatewayAPI: true
```

**Do NOT use the deprecated featureGates approach:**

```yaml
# DEPRECATED - does not work in recent versions
extraArgs:
  - --feature-gates=ExperimentalGatewayAPISupport=true
```

## Step 2: Restart cert-manager After RBAC Update

The Helm upgrade creates new RBAC rules (ClusterRole/ClusterRoleBinding) that
grant cert-manager permission to watch and update Gateway API resources. The
running cert-manager pods will not pick up these permissions until they restart:

```bash
kubectl rollout restart deployment cert-manager -n cert-manager
kubectl rollout status deployment cert-manager -n cert-manager
```

## Step 3: Create a Gateway-Specific ClusterIssuer

Your existing ClusterIssuer likely uses an http01 solver configured for
ingress-nginx:

```yaml
# Existing issuer (for ingress-nginx)
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: certs@example.com
    privateKeySecretRef:
      name: letsencrypt-prod-key
    solvers:
      - http01:
          ingress:
            ingressClassName: nginx
```

Create a second issuer that uses the Gateway API http01 solver:

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod-gateway
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: certs@example.com
    privateKeySecretRef:
      name: letsencrypt-prod-gateway-key
    solvers:
      - http01:
          gatewayHTTPRoute:
            parentRefs:
              - name: my-gateway
                namespace: envoy-gateway-system
                kind: Gateway
```

Apply and verify:

```bash
kubectl apply -f clusterissuer-gateway.yaml
kubectl get clusterissuer letsencrypt-prod-gateway
# STATUS should show Ready: True
```

## Step 4: Verify Gateway API Watching

Confirm cert-manager is watching Gateway resources:

```bash
kubectl logs deployment/cert-manager -n cert-manager | grep -i gateway
```

You should see log lines indicating cert-manager is watching Gateway and
HTTPRoute resources.

## TLS Certificate Lifecycle During Migration

### Before DNS Cutover (Chicken-and-Egg Problem)

cert-manager's http01 solver cannot complete the ACME challenge on the Envoy
Gateway because DNS still points to nginx. To work around this:

1. Copy the existing TLS secret to the `envoy-gateway-system` namespace:

```bash
kubectl get secret app-tls -n my-app -o yaml \
  | sed 's/namespace: my-app/namespace: envoy-gateway-system/' \
  | kubectl apply -f -
```

2. Reference this secret in the Gateway listener TLS config:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: my-gateway
  namespace: envoy-gateway-system
spec:
  listeners:
    - name: app-https
      port: 443
      protocol: HTTPS
      hostname: "app.example.com"
      tls:
        mode: Terminate
        certificateRefs:
          - name: app-tls
            kind: Secret
      allowedRoutes:
        namespaces:
          from: All
```

### After DNS Cutover

Once DNS points to the Envoy LB IP, cert-manager can reach the http01
challenge endpoint through Envoy. It will automatically renew the certificate
when it approaches expiration. No further manual intervention is needed.

### Verification

```bash
# Check certificate status
kubectl get certificate -A | grep app

# Check certificate details
kubectl describe certificate app-tls -n envoy-gateway-system

# Check the ACME challenge (if renewal is in progress)
kubectl get challenges -A
```

## Troubleshooting

| Symptom | Likely Cause | Fix |
|---------|-------------|-----|
| ClusterIssuer not Ready | ACME registration failed | Check cert-manager logs, verify email and ACME server URL |
| Certificate stuck Pending | http01 challenge unreachable | DNS still points to nginx; copy secret manually |
| cert-manager not watching Gateways | `enableGatewayAPI` not set or pod not restarted | Set the config value and restart the deployment |
| RBAC errors in logs | Helm upgrade did not run or CRDs missing | Ensure Gateway API CRDs are installed; re-run Helm upgrade |
