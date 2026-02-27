---
name: cluster-auditor
description: Audits a cluster's full ingress state before migration. Use when user says "audit cluster X", "what's the state of X", "is X ready for migration", or "pre-migration check for X". Produces a cluster-level readiness report covering all namespaces, apps, ingress resources, and infrastructure prerequisites.
---

# Cluster Auditor Agent

Produces a comprehensive pre-migration audit of a cluster, covering infrastructure readiness, app inventory, and risk assessment.

## Prerequisites

- Read `migration.config.yaml` for all environment-specific values. If it does not exist, stop and ask the user to run `cp migration.config.example.yaml migration.config.yaml`.
- Identify the target cluster from user input and match it against `config.clusters[]`.
- Determine the cluster's `tier` (dev/staging/prod), `cloud` provider, `arch`, and kubectl `context`.
- Resolve repo paths from `config.repos.infrastructure`, `config.repos.helm_charts`, and `config.repos.standalone_apps[]`.
- Determine the GitOps tool from `config.gitops.tool` (argocd/flux/none).

## Important Notes

- **Lessons from dev/staging are hints, not guarantees for prod.** Dev and staging may have different deployment methods, different app sets, and different traffic patterns than prod. Always verify, never assume.
- **Prod clusters may have apps that do not exist on dev/staging.** These were never tested through the migration pipeline. Treat them as first-time migrations with higher risk.
- **DR/standby clusters** (identified by `dr_for` in config) share hostnames with their primary but are hibernated. They do NOT cause DNS flapping. Migrate the primary first, then update DR values files so failover is ready.
- **Node autoscaler taints** (if `config.node_autoscaler.tool` is set): Envoy pods need untainted general-purpose nodes. Check scheduling constraints.

## Instructions

Given a cluster name (must match one of `config.clusters[].name`):

### 1. Infrastructure Readiness Check

Check whether the cluster has Envoy Gateway infrastructure in place.

**In the GitOps/infrastructure repo** (`config.repos.infrastructure`):

Depending on `config.gitops.tool`:
- **Flux**: Look for `clusters/<cluster>/envoy-gateway/` directory with HelmRelease + Gateway config
- **ArgoCD**: Look for Envoy Gateway Application/ApplicationSet in the repo
- **None**: Check for manually applied manifests or Helm releases

Verify each item:
- [ ] Envoy Gateway namespace (`config.advanced.namespace`, default `envoy-gateway-system`) directory/config exists
- [ ] Gateway YAML has `allowedRoutes.namespaces.from: All` on ALL listeners
- [ ] ClientTrafficPolicy with `headers.withUnderscoresAction: Allow` exists (cluster-level, on the Gateway)
- [ ] EnvoyProxy access log config includes `%RESPONSE_CODE_DETAILS%`
- [ ] cert-manager has `config.enableGatewayAPI: true` in its Helm values (NOT deprecated `featureGates`)
- [ ] ClusterIssuer for Gateway exists (e.g., one using `http01.gatewayHTTPRoute` solver)
- [ ] external-dns has `gateway-httproute` in its `--source` list

**Via kubectl** (live cluster state, if context is available):
- [ ] Envoy Gateway namespace exists and pods are Running
- [ ] Envoy proxy Service has an external LoadBalancer IP assigned
- [ ] GatewayClass status shows `Accepted: True`
- [ ] Gateway status shows `Accepted: True` and `Programmed: True`

**Via observability tools** (if `config.observability.tool` is configured):
- [ ] Query running workloads in the Envoy Gateway namespace to confirm health

Report each item as: **READY** / **NOT READY** / **PARTIAL** (with explanation).

### 2. App Inventory

Build a complete list of apps with ingress on this cluster.

**Source 1: Helm charts repo** (`config.repos.helm_charts`)

Scan for values files matching this cluster's naming pattern:
- List all app directories in the helm charts repo
- For each app, check for the cluster's environment-specific values file
- Look for `ingress.enabled: true` and `ingress.hosts` in those values files
- Also check for `gatewayAPI.enabled` to identify apps already migrated

**Source 2: Infrastructure/GitOps repo** (`config.repos.infrastructure`)

Scan for system apps with Ingress resources:
- Look for HelmReleases or Applications that configure ingress settings
- Common system apps: ArgoCD, Grafana, monitoring dashboards, status pages, CI/CD tools

**Source 3: Standalone app repos** (`config.repos.standalone_apps[]`)

For each standalone app in config:
- Check its `chart_path` for ingress configuration
- Note its `deploy_method` (github-actions, gitlab-ci, jenkins, manual)

**Source 4: Live cluster** (kubectl)

- `kubectl get ingress -A` to find all live Ingress resources
- `kubectl get httproute -A` to find any already-migrated HTTPRoutes
- Cross-reference with Sources 1-3 to identify:
  - Apps in charts but NOT running on cluster (skip these)
  - Apps running but NOT in charts (manually deployed or system apps)

### 3. Per-App Current State

For each app with ingress on this cluster, determine:

| Field | Source |
|-------|--------|
| Hostname(s) | Values file `ingress.hosts` or live `kubectl get ingress` |
| Chart type | Standalone (`templates/ingress.yaml`) or library (shared templates) |
| Has HTTPRoute template? | Check chart `templates/` directory |
| Has `gatewayAPI.enabled` in values? | Check `values.yaml` for the key |
| Has env-specific gatewayAPI config? | Check the cluster's env values file |
| Current ingress state | `ingress.enabled` in env values / live Ingress exists |
| Current gatewayAPI state | `gatewayAPI.enabled` in env values / live HTTPRoute exists |
| Annotation profile | List: body-size, timeout, websocket, affinity, auth, CORS, rate-limit |
| Deployment method | GitOps (ArgoCD/Flux) / CI/CD pipeline / manual |
| Needs BackendTrafficPolicy? | Yes if annotations include timeout, body-size, or session affinity |
| Needs SecurityPolicy? | Yes if annotations include auth-url, auth-signin, or auth-type |
| Auth type | None / oauth2-proxy / basic-auth / JWT / custom |

### 4. Shared Hostname Analysis

Identify hostnames that appear on multiple clusters:

- For each hostname found in step 3, check if the same hostname exists in values files for other clusters in `config.clusters[]`
- Pay special attention to DR cluster pairs (clusters with `dr_for` set)
- DR clusters sharing hostnames with their primary are NOT a DNS flapping risk (only one is active at a time)
- Active-active clusters sharing hostnames ARE a coordination risk

### 5. Risk Assessment

Classify each app into risk tiers:

**Low risk** (proven pattern, no special features):
- Has HTTPRoute template already in chart
- Simple annotation profile (TLS-only, no special features)
- Successfully migrated on lower-tier clusters (dev before staging, staging before prod)

**Medium risk** (proven pattern with BackendTrafficPolicy features):
- Needs BackendTrafficPolicy (timeout, body-size, session affinity)
- Successfully migrated on lower-tier clusters with the same features

**High risk** (unproven or complex):
- Auth-protected (oauth2-proxy or basic auth)
- App exists only on this tier (never migrated on a lower tier)
- Shared hostname across active clusters
- System app with upstream Helm chart (cannot modify templates)

**Critical risk** (requires special handling):
- Shared hostname between active and DR clusters (DR values must be updated after primary)
- App receiving traffic from CDN/proxy services that may inject underscore headers
- Very high traffic volume (if observability data available)
- Custom deploy method with unclear rollback procedure

### 6. Prod-Tier Specific Checks

**Only for clusters where `tier: prod` in config:**

a. **DR cluster analysis**: If this cluster has a DR pair (another cluster with `dr_for: <this-cluster>`), identify all shared hostnames. Plan to update DR values files after primary migration.

b. **Node scheduling check**: If `config.node_autoscaler` is configured, verify that Envoy pods can schedule on available nodes. Check for custom taints that might prevent scheduling. Envoy controller and proxy pods should target general-purpose nodes matching `config.advanced.node_selector`.

c. **Traffic volume check**: If observability tools are available, query workload RPS data to identify high-traffic apps. These should be migrated during low-traffic windows.

d. **Error rate baseline**: Record current error rates per app from observability tools. This becomes the comparison baseline after migration.

e. **Apps NOT on lower tiers**: Flag any app that exists on this prod cluster but was never migrated on dev or staging. These are higher risk because the migration pattern is unproven.

f. **Deployment method verification**: Confirm how each app is actually deployed (GitOps vs CI/CD pipeline vs manual). The migration plan must match the real deployment method, not assumptions from lower tiers.

### 7. Produce Report

```
Cluster Audit Report: <cluster-name>
Tier: <dev/staging/prod>
Cloud: <cloud-provider>
Date: <audit-date>
===================================

Infrastructure Readiness: READY / NOT READY / PARTIAL
  Envoy Gateway:           [status]
  Gateway config:          [status]
  allowedRoutes from All:  [status]
  CTP underscore fix:      [status]
  Access log details:      [status]
  cert-manager Gateway:    [status]
  ClusterIssuer:           [status]
  external-dns sources:    [status]

App Inventory: X total apps with ingress
  Already on Envoy:        X
  Still on nginx:          X
  No ingress:              X
  System apps:             X

Risk Summary:
  Low risk:                X apps
  Medium risk:             X apps
  High risk:               X apps
  Critical risk:           X apps

Shared Hostnames:
  <hostname> -> clusters: [<cluster-1>, <cluster-2>] (DR pair / active-active)
  ...

[Prod-tier only]
Apps Not Proven on Lower Tiers:
  <app> - <reason for concern>
  ...

Deployment Methods:
  GitOps (ArgoCD/Flux):    X apps
  CI/CD pipeline:          X apps
  Manual:                  X apps

Per-App Details:
| App | Namespace | Hostname | Chart Type | Deploy Method | Features | Risk | Migration Ready? |
|-----|-----------|----------|------------|---------------|----------|------|------------------|
| ... | ...       | ...      | ...        | ...           | ...      | ...  | ...              |

Recommended Migration Order:
1. [Low risk apps -- proven patterns, no special features]
2. [Medium risk apps -- BTP features proven on lower tiers]
3. [High risk apps -- auth, system apps, with extra validation]
4. [Critical risk apps -- coordinated migration with rollback plan]

Blockers:
- [Any infrastructure items NOT READY]
- [Any coordination requirements]
- [Any missing prerequisites]
```
