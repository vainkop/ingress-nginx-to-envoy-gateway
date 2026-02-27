# Helm Template Strategy for Dual Ingress/Gateway Support

When migrating a fleet of applications from ingress-nginx to Envoy Gateway, your
Helm charts need to support both systems simultaneously. Different clusters may
be at different stages of migration. This document covers the template strategy,
values management, and validation workflow.

---

## Standalone vs Library Charts

### Standalone Charts

Charts with their own `templates/ingress.yaml`. Each chart is independent and
can be modified without affecting other apps.

- Safer to modify: changes only affect the single application.
- Can add Gateway API templates directly to `templates/`.
- Start migrations with these charts since the blast radius is minimal.

### Library Charts (Shared)

A common library chart used by multiple applications via `dependencies` in
`Chart.yaml`. Changes to the library chart affect all consuming apps across all
clusters immediately.

- Higher risk: a bad template change breaks every app using the library.
- Must gate new templates on multiple conditions (see below).
- Requires `helm dependency update` in each consuming chart after changes.
- Always run full validation (lint + template + schema validation) before
  committing.

---

## Gating on gatewayAPI.enabled

Add a boolean flag that controls whether Gateway API resources are rendered:

```yaml
# values.yaml (root - default)
gatewayAPI:
  enabled: false
```

In templates, conditionally render HTTPRoute and policies:

```yaml
# templates/httproute.yaml
{{- if .Values.gatewayAPI.enabled }}
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: {{ include "mychart.fullname" . }}
spec:
  parentRefs:
    - name: {{ .Values.gatewayAPI.gatewayName | default "my-gateway" }}
      namespace: {{ .Values.gatewayAPI.gatewayNamespace | default "envoy-gateway-system" }}
  hostnames:
    - {{ .Values.gatewayAPI.hostname | default .Values.ingress.hostname }}
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: {{ include "mychart.fullname" . }}
          port: {{ .Values.service.port }}
{{- end }}
```

For library charts used by multiple app "roles" (e.g., web, worker, cron), gate
on both the role and the feature flag:

```yaml
{{- if and (eq .Values.role "web") .Values.gatewayAPI.enabled }}
# ... HTTPRoute template ...
{{- end }}
```

---

## Values Loading Order and Blast Radius

Helm merges values files in order. Later files override earlier ones. A typical
multi-file setup:

```
values.yaml                    # Base defaults (all clusters)
  -> web-values.yaml           # Web-role overrides
    -> env-values.yaml         # Environment-specific (e.g., dev, staging, prod)
```

### The web-values.yaml Override Problem

If `web-values.yaml` sets `ingress.enabled: true` and it is loaded after your
environment override, the web-values file wins:

```yaml
# web-values.yaml
ingress:
  enabled: true    # <-- This overrides your env-specific false
```

**Solution:** Create an explicit override file loaded last:

```yaml
# web-env-override-values.yaml (loaded last in the chain)
ingress:
  enabled: false
gatewayAPI:
  enabled: true
```

Ensure your HelmRelease or ArgoCD Application lists this file last:

```yaml
# Flux HelmRelease example
spec:
  valuesFrom:
    - kind: ConfigMap
      name: app-values
    - kind: ConfigMap
      name: app-web-values
    - kind: ConfigMap
      name: app-env-values
    - kind: ConfigMap
      name: app-web-env-override     # Loaded last, wins all conflicts
```

---

## Root values.yaml Safety

**Never set `gatewayAPI.enabled: true` in the root `values.yaml`.**

The root values file applies to all clusters. If some clusters have not yet
deployed Envoy Gateway, setting this globally will create HTTPRoute resources
that reference a non-existent Gateway, causing errors.

Only enable Gateway API in environment-specific or cluster-specific values
files:

```yaml
# values.yaml (root) - SAFE
gatewayAPI:
  enabled: false

# dev-values.yaml - OK, only affects dev
gatewayAPI:
  enabled: true

# staging-values.yaml - OK, only affects staging
gatewayAPI:
  enabled: true
```

This limits the blast radius to one cluster at a time.

---

## Validation Workflow

Before committing any template changes, run the full validation pipeline:

### 1. Helm Lint

Catches syntax errors and template issues:

```bash
helm lint ./mychart -f values.yaml -f web-values.yaml -f dev-values.yaml
```

Run lint with BOTH `gatewayAPI.enabled: true` and `false` to validate both
code paths:

```bash
helm lint ./mychart --set gatewayAPI.enabled=false
helm lint ./mychart --set gatewayAPI.enabled=true
```

### 2. Helm Template

Renders the templates to YAML. Inspect the output for correctness:

```bash
# With Ingress (existing path)
helm template myapp ./mychart \
  -f values.yaml -f web-values.yaml \
  --set gatewayAPI.enabled=false | grep -A 20 "kind: Ingress"

# With HTTPRoute (new path)
helm template myapp ./mychart \
  -f values.yaml -f web-values.yaml \
  --set gatewayAPI.enabled=true | grep -A 20 "kind: HTTPRoute"

# Verify NO Ingress when gatewayAPI is enabled
helm template myapp ./mychart \
  --set gatewayAPI.enabled=true | grep "kind: Ingress"
# Should return nothing
```

### 3. Schema Validation (kubeconform)

Validates rendered YAML against Kubernetes and Gateway API schemas:

```bash
helm template myapp ./mychart --set gatewayAPI.enabled=true \
  | kubeconform \
    -schema-location default \
    -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
    -strict \
    -summary
```

### 4. Verify Mutual Exclusivity

Ensure Ingress and HTTPRoute are never rendered simultaneously:

```bash
# This should render ONLY Ingress, NOT HTTPRoute
helm template myapp ./mychart --set gatewayAPI.enabled=false \
  | grep "kind:" | sort -u

# This should render ONLY HTTPRoute, NOT Ingress
helm template myapp ./mychart --set gatewayAPI.enabled=true \
  | grep "kind:" | sort -u
```

---

## Library Chart Update Workflow

When modifying a shared library chart:

1. Make changes in the library chart `templates/` directory.
2. Run lint and template in the library chart itself.
3. For each consuming chart:
   a. Run `helm dependency update` to pick up the library change.
   b. Run the full validation workflow (lint, template, kubeconform).
   c. Test with both `gatewayAPI.enabled: true` and `false`.
4. Only commit after all consuming charts pass validation.
