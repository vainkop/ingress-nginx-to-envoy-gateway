# Decommissioning ingress-nginx

After all applications have been migrated to Envoy Gateway, ingress-nginx can
be scaled down and eventually removed. This must be done carefully to preserve
rollback capability and avoid orphaned resources.

---

## When It Is Safe to Decommission

All of the following must be true:

- [ ] Every application has been migrated and validated on Envoy Gateway
- [ ] No Ingress resources remain in any namespace (excluding system apps
      like kubernetes-dashboard that may have their own)
- [ ] DNS records all point to the Envoy Gateway LoadBalancer IP
- [ ] TLS certificates are being issued and renewed via the Gateway-based
      ClusterIssuer
- [ ] At least 1-2 weeks of stable operation on Envoy Gateway (covers
      certificate renewal cycles)
- [ ] Monitoring confirms zero traffic on the nginx LoadBalancer IP

---

## Step 1: Disable HPA First

If the ingress-nginx controller has a HorizontalPodAutoscaler, it will fight
your replicaCount changes. Disable it first:

```yaml
# ingress-nginx Helm values
controller:
  autoscaling:
    enabled: false
```

Apply the change and verify the HPA is removed:

```bash
kubectl get hpa -n ingress-nginx
# Should return no resources
```

---

## Step 2: Scale Down (Do Not Delete Yet)

Scale the controller to 0 replicas but keep the Helm release and Service:

```yaml
controller:
  autoscaling:
    enabled: false
  replicaCount: 0
```

This stops the pods but preserves:

- The LoadBalancer Service (and its allocated IP)
- The Helm release metadata
- All configuration for quick rollback

Verify:

```bash
kubectl get pods -n ingress-nginx
# Should show no controller pods

kubectl get svc -n ingress-nginx
# LoadBalancer Service should still exist with its IP
```

---

## Step 3: Preserve the LoadBalancer IP (Rollback Safety)

**Do NOT delete the Service yet.** If you delete the LoadBalancer Service, the
cloud provider may reclaim the IP address. If you need to rollback, you would
get a different IP, requiring DNS changes for every app.

Keep the Service alive (even with 0 backend pods) until you are confident the
migration is permanent.

---

## Step 4: Clean Up Stale DNS Records

If your external-dns uses `upsert-only` policy, old DNS records pointing to
the nginx LoadBalancer IP will not be automatically deleted. Clean them up
manually:

```bash
# Check for any DNS records still pointing to the old nginx IP
# Use your DNS provider CLI or web console

# Example: List records for a domain
dig +short app.example.com
# Should return the Envoy LB IP, not the nginx IP
```

Remove any stale A records via your DNS provider's API or dashboard.

---

## Step 5: Rollback From Scaled-Down State

If issues are discovered and you need nginx back:

1. Re-enable in Helm values:

```yaml
controller:
  replicaCount: 2    # or your previous value
```

2. Apply the change. Pods will start immediately since the Service (and its
   IP) still exists.

3. Recreate the Ingress resources (revert the `ingress.enabled: false` change
   for the affected apps).

4. external-dns will update DNS to point back to the nginx IP.

This rollback is fast because the LoadBalancer IP was preserved.

---

## Step 6: Final Removal

Once you are confident the migration is permanent (recommended: 4+ weeks of
stable operation):

1. Delete the ingress-nginx Helm release:

```bash
helm uninstall ingress-nginx -n ingress-nginx
```

2. Remove the namespace (if dedicated):

```bash
kubectl delete namespace ingress-nginx
```

3. Remove the IngressClass resource if it was not cleaned up:

```bash
kubectl delete ingressclass nginx
```

4. Clean up any remaining CRDs or admission webhooks:

```bash
kubectl get validatingwebhookconfigurations | grep nginx
kubectl delete validatingwebhookconfigurations ingress-nginx-admission
```

5. Remove ingress-nginx from your infrastructure-as-code (Flux HelmRelease,
   Terraform, ArgoCD Application, etc.).

6. Do a final DNS audit to confirm no records point to the now-released IP.

---

## Timeline Summary

| Phase | Duration | State |
|-------|----------|-------|
| Scale down | Week 0 | 0 pods, Service preserved, LB IP held |
| Monitor | Weeks 1-4 | Verify no traffic on old IP, certs renewing |
| Final removal | Week 4+ | Delete Helm release, clean up namespace |
| DNS audit | After removal | Remove stale records, verify all apps |
