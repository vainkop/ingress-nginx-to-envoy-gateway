---
name: migration-researcher
description: Researches a specific app's ingress configuration across repos and live cluster. Use when user says "research app X", "what ingress config does X have", "analyze X before migration", or before migrating an app to gather its full ingress profile. Produces a structured config report.
---

# Migration Researcher Agent

Gathers the full ingress configuration profile for a specific app before migration. This is a deep-dive on a single app, complementing the cluster-wide view from `cluster-auditor`.

## Prerequisites

- Read `migration.config.yaml` for repo paths, cluster names, GitOps tool, and auth settings.
- If the file does not exist, stop and ask the user to run `cp migration.config.example.yaml migration.config.yaml`.

## Important Notes

- **Some apps are NOT deployed on all clusters.** Check live cluster state; do not assume chart existence means the app is running.
- **Deployment methods may differ by cluster tier.** Dev/staging may use GitOps while prod uses CI/CD pipelines. Check per-cluster, do not assume.
- **Standalone apps** (listed in `config.repos.standalone_apps[]`) have their own repos and deploy methods. Ingress changes go in their own repo, not in the shared helm charts repo.

## Instructions

Given an app name and optionally a cluster name:

### 1. Find the Helm Chart

Search for the app's chart in multiple locations:

**Shared helm charts repo** (`config.repos.helm_charts`):
- Look for `<app-name>/` directory
- Read `Chart.yaml` to determine chart type (standalone vs library dependency)
- Read `templates/ingress.yaml` to understand the ingress template structure
- Check if `templates/httproute.yaml` already exists (may have been added during earlier tier migration)
- Check if `templates/backendtrafficpolicy.yaml` exists
- Read `values.yaml` for default ingress config and `gatewayAPI` defaults
- Read ALL environment-specific values files (`*-values.yaml`) to see per-cluster overrides
- Collect: all annotations, hosts, paths, TLS config per environment

**Standalone app repos** (`config.repos.standalone_apps[]`):
- If the app name matches a standalone app in config, look in its `chart_path`
- Read the same files as above from that repo instead

**Infrastructure/GitOps repo** (`config.repos.infrastructure`):
- For system apps (those using upstream Helm charts), look for HelmRelease or Application config
- Check for any ingress-related Helm values overrides

### 2. Find the GitOps/Deployment Configuration

Based on `config.gitops.tool`:

**ArgoCD**:
- Search for Application or ApplicationSet referencing this app
- Read the YAML to understand: which values files are layered, release name, target namespace
- Note the values file load order (important for override behavior)

**Flux**:
- Search for HelmRelease or Kustomization referencing this app
- Check valuesFrom and values overrides

**CI/CD pipeline** (for standalone apps or prod-tier clusters that use pipelines):
- Check the app's repo for CI/CD config (GitHub Actions workflows, GitLab CI, Jenkinsfile)
- Understand how Helm values are passed (e.g., `helm upgrade --install -f values.yaml -f env-values.yaml`)
- Note if any values are injected at deploy time via `--set` (common for secrets, basic auth passwords)

### 3. Check Live Cluster State

If a cluster name is provided and kubectl context is available:

```bash
# Check if the app has a live Ingress
kubectl get ingress -n <namespace> -l app.kubernetes.io/name=<app-name>

# Check if the app already has an HTTPRoute
kubectl get httproute -n <namespace> -l app.kubernetes.io/name=<app-name>

# Check the running pods
kubectl get pods -n <namespace> -l app.kubernetes.io/name=<app-name>

# Get the full Ingress YAML for annotation details
kubectl get ingress -n <namespace> <ingress-name> -o yaml
```

If observability tools are available (`config.observability.tool`):
- Query workload data to confirm the app is running and receiving traffic
- Check recent traces for HTTP methods, paths, and status codes
- Check logs for any ingress-related errors

### 4. Annotation-to-Resource Mapping

Map every nginx annotation found to the equivalent Envoy Gateway resource:

| nginx annotation | Envoy Gateway resource | Field path |
|-----------------|----------------------|------------|
| `kubernetes.io/tls-acme: "true"` | HTTPRoute only | No extra resource needed |
| `nginx.ingress.kubernetes.io/proxy-body-size` | BackendTrafficPolicy | `spec.requestBuffer.limit` (use `Mi`/`Gi`) |
| `nginx.ingress.kubernetes.io/proxy-read-timeout` | BackendTrafficPolicy | `spec.timeout.http.requestTimeout` |
| `nginx.ingress.kubernetes.io/proxy-send-timeout` | BackendTrafficPolicy | `spec.timeout.http.requestTimeout` |
| `nginx.ingress.kubernetes.io/proxy-connect-timeout` | BackendTrafficPolicy | `spec.timeout.tcp.connectTimeout` |
| `nginx.ingress.kubernetes.io/websocket-services` | (native in Envoy) | Ensure long timeout on BTP |
| `nginx.ingress.kubernetes.io/affinity: cookie` | BackendTrafficPolicy | `spec.loadBalancer.consistentHash.cookie` |
| `nginx.ingress.kubernetes.io/session-cookie-name` | BackendTrafficPolicy | `spec.loadBalancer.consistentHash.cookie.name` |
| `nginx.ingress.kubernetes.io/auth-url` | HTTPRoute to oauth2-proxy | Reverse proxy pattern (NOT SecurityPolicy extAuth) |
| `nginx.ingress.kubernetes.io/auth-signin` | HTTPRoute to oauth2-proxy | Reverse proxy pattern |
| `nginx.ingress.kubernetes.io/auth-type: basic` | SecurityPolicy | `spec.basicAuth.users` (`.htpasswd` key, SHA hash) |
| `nginx.ingress.kubernetes.io/backend-protocol: HTTPS` | BackendTLSPolicy | Separate resource |
| `nginx.ingress.kubernetes.io/cors-*` | SecurityPolicy or filter | Depends on complexity |

### 5. Produce Report

```
App Research Report: <app-name>
Cluster: <cluster-name> (or "all clusters")
========================================

Chart Location: <repo-path>/<app>/
Chart Type: standalone / library
Namespace: <namespace>
Deploy Method: ArgoCD / Flux / CI/CD pipeline (<tool>) / manual

Ingress Template: <path>/templates/ingress.yaml
HTTPRoute Template: exists / does not exist
BTP Template: exists / does not exist

Ingress Profile:
  className: nginx
  annotations:
    <annotation-key>: <value>
    ...

Per-Environment Config:
  <env-1> (<cluster-name>):
    host: <hostname>
    tls: <secret-name>
    ingress.enabled: true/false
    gatewayAPI.enabled: true/false/not set
    overrides: <any env-specific annotation overrides>
  <env-2>:
    ...

Values File Load Order:
  1. values.yaml
  2. <env>-values.yaml
  3. [role-values.yaml if library chart]
  4. [override-values.yaml if needed]

Auth Configuration:
  Type: none / oauth2-proxy / basic-auth / JWT
  [Details of auth setup if applicable]

Migration Complexity: Simple / BTP-required / Auth-required / System-app
Required Envoy Gateway Resources:
  - HTTPRoute (always)
  - BackendTrafficPolicy (if timeout/body-size/affinity needed)
  - SecurityPolicy (if basic auth needed)
  - BackendTLSPolicy (if backend speaks HTTPS)
Gateway Listeners Needed: <list of hostnames that need HTTPS listeners>

Special Considerations:
  - [Any web-values override issue for library charts]
  - [Any CI-injected values via --set]
  - [Any shared hostname across clusters]
  - [Any prod-only concerns]
```
