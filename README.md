# ingress-nginx to Envoy Gateway Migration Guide

[![CI](https://github.com/vainkop/ingress-nginx-to-envoy-gateway/actions/workflows/ci.yaml/badge.svg)](https://github.com/vainkop/ingress-nginx-to-envoy-gateway/actions/workflows/ci.yaml)

The production-tested, AI-powered migration guide for moving from ingress-nginx to [Envoy Gateway](https://gateway.envoyproxy.io/) (Kubernetes Gateway API).

## Author

**Valerii Vainkop** — DevOps Team Leader at [GlobalDots](https://www.globaldots.com)

- LinkedIn: [linkedin.com/in/valeriiv](https://www.linkedin.com/in/valeriiv)
- Telegram: [@vainkop](https://t.me/vainkop)
- Blog: [dev.to/vainkop](https://dev.to/vainkop)

Built from real-world experience migrating 124+ production apps across multiple Kubernetes clusters.
Need help with your migration? Reach out directly or via [GlobalDots](https://www.globaldots.com).

## Why This Repo?

Existing migration resources (`ingress2gateway`, Envoy Gateway docs, blog posts) cover the **20%** -- install Envoy Gateway, convert YAML. This repo covers the **80% they skip**:

- **17 battle-tested gotchas** with symptoms, root causes, and fixes ([docs/gotchas.md](docs/gotchas.md))
- **28+ nginx annotation mappings** to Envoy Gateway CRDs with correct field paths and format gotchas
- **Auth migration patterns** that actually work (oauth2-proxy, basic auth, JWT) ([docs/auth-migration-patterns.md](docs/auth-migration-patterns.md))
- **DNS cutover strategy** that prevents downtime ([docs/dns-cutover-strategy.md](docs/dns-cutover-strategy.md))
- **CRD field traps** in Envoy Gateway v1.7.0 that waste hours ([docs/envoy-gateway-v1.7-crd-reference.md](docs/envoy-gateway-v1.7-crd-reference.md))
- **Claude Code agents and skills** that form an executable migration pipeline

> **Note**: The documentation and examples are fully usable without Claude Code. The AI agents and skills accelerate the workflow but are not required.

## Version Compatibility

| Component | Version | Notes |
|-----------|---------|-------|
| Envoy Gateway | v1.7.0 | Released Feb 5, 2026 |
| Gateway API | v1.4.1 | Per [compatibility matrix](https://gateway.envoyproxy.io/news/releases/matrix/) |
| ingress-nginx | v4.x | Source controller (any recent version) |
| Kubernetes | 1.28+ | Gateway API requires 1.28+ |
| cert-manager | v1.14+ | For Gateway API support |

> **Note**: Gateway API v1.5.0 exists but is NOT yet supported by Envoy Gateway v1.7.0.

## Prerequisites

- `kubectl` access to your Kubernetes cluster(s)
- `helm` v3 for chart management
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) (optional, for AI-powered agents and skills)

## Quick Start

### 1. Clone and configure

```bash
git clone https://github.com/vainkop/ingress-nginx-to-envoy-gateway.git
cd ingress-nginx-to-envoy-gateway
cp migration.config.example.yaml migration.config.yaml
# Edit migration.config.yaml with your cluster/repo details
```

### 2. Start Claude Code

```bash
claude
```

Claude reads CLAUDE.md and your config automatically. You now have access to the full migration toolkit.

### 3. Audit your cluster

```
> Audit my dev cluster for Envoy Gateway readiness
```

The `cluster-auditor` agent checks infrastructure prerequisites, inventories all ingress resources, classifies migration complexity, and produces a risk assessment.

### 4. Migrate an app

```
> Analyze the ingress for my-app in namespace my-app
> Generate the HTTPRoute for my-app
> Migrate my-app to Envoy Gateway
```

Skills guide you through each step with validation.

## Recommended Workflow

The full migration pipeline follows 10 steps:

1. **Configure** -- Populate `migration.config.yaml` with your environment details
2. **Pre-flight** -- `/pre-flight-check` to verify cluster prerequisites (CRDs, cert-manager, Gateway)
3. **Audit** -- `cluster-auditor` agent for full cluster state and app inventory
4. **Research** -- `migration-researcher` agent for per-app deep dive (optional)
5. **Plan** -- `migration-planner` agent to produce a reviewable plan with exact file changes
6. **Review** -- `plan-reviewer` agent to check the plan against 22+ known failure modes
7. **Execute** -- `/migrate-app` skill to implement the approved plan
8. **Validate** -- `/validate-migration` skill to verify everything works
9. **Track** -- Update migration status
10. **Repeat** -- Move to the next cluster tier (dev → staging → prod)

## What's Included

### AI Agents (`.claude/agents/`)

Agents form a pipeline: **audit → research → plan → review → execute → validate**

| Agent | Purpose |
|-------|---------|
| `cluster-auditor` | Full cluster readiness assessment and app inventory |
| `migration-researcher` | Deep-dive into a specific app's ingress configuration |
| `migration-planner` | Produces a concrete, reviewable migration plan with exact file changes |
| `plan-reviewer` | Adversarial review of plans against 22+ known failure modes |

### Skills (`.claude/skills/`)

Built following [Anthropic's Complete Guide to Building Skills for Claude](https://claude.com/blog/complete-guide-to-building-skills-for-claude) ([PDF](https://resources.anthropic.com/hubfs/The-Complete-Guide-to-Building-Skill-for-Claude.pdf)).

| Skill | Purpose |
|-------|---------|
| `/setup-cluster` | Deploy Envoy Gateway and configure cluster prerequisites |
| `/analyze-ingress` | Parse a live Ingress and classify migration complexity |
| `/generate-httproute` | Generate ready-to-apply HTTPRoute + policy YAML from an Ingress |
| `/pre-flight-check` | Verify all cluster prerequisites before migration |
| `/migrate-app` | Step-by-step workflow for migrating a single app |
| `/validate-migration` | Post-migration validation checklist |

### Documentation (`docs/`)

| Document | Description |
|----------|-------------|
| [gotchas.md](docs/gotchas.md) | **17 battle-tested gotchas** -- the flagship content |
| [auth-migration-patterns.md](docs/auth-migration-patterns.md) | oauth2-proxy, basic auth, JWT patterns |
| [dns-cutover-strategy.md](docs/dns-cutover-strategy.md) | Zero-downtime DNS switching |
| [cert-manager-gateway-setup.md](docs/cert-manager-gateway-setup.md) | cert-manager + Gateway API setup |
| [envoy-gateway-v1.7-crd-reference.md](docs/envoy-gateway-v1.7-crd-reference.md) | CRD fields that exist vs don't |
| [debugging-underscore-headers.md](docs/debugging-underscore-headers.md) | Fixing mysterious 400 errors |
| [helm-template-strategy.md](docs/helm-template-strategy.md) | Standalone vs library chart patterns |
| [decommission-nginx.md](docs/decommission-nginx.md) | Safe nginx teardown procedure |

### Examples (`examples/`)

Ready-to-apply YAML with `# REPLACE:` comments:

- **`gateway/`** -- GatewayClass, EnvoyProxy, Gateway, ClientTrafficPolicy, ClusterIssuer
- **`httproute/`** -- 12 patterns: simple routing, BackendTrafficPolicy, WebSocket, session affinity, basic auth, oauth2-proxy, system apps, GRPCRoute, SSL passthrough (TLSRoute), IP allowlist/denylist, HTTP-to-HTTPS redirect, cross-namespace ReferenceGrant
- **`helm-values/`** -- Helm values for different app complexity levels
- **`flux/`** -- HelmRelease and Kustomization patterns
- **`argocd/`** -- ApplicationSet with gateway override values

## Migration Strategy

### Phase 0: Infrastructure Setup
Deploy Envoy Gateway alongside nginx (separate LoadBalancer, separate IP). Both run simultaneously.

### Phase 1: Migrate Dev Apps
Start with simple apps (no auth, no WebSocket, no session affinity). Build confidence.

### Phase 2: Migrate Staging Apps
Migrate all apps including complex ones (auth, WebSocket, session affinity).

### Phase 3: Migrate Production Apps
Same patterns proven in dev/staging. Extra care with rollback procedures and traffic monitoring.

### Phase 4: Decommission nginx
Scale down nginx (don't delete yet). Monitor. Clean up DNS records. Eventually remove.

### Key Rules

1. **Never run both Ingress and HTTPRoute for the same hostname** -- causes DNS record flapping
2. **DNS cutover must be atomic** -- disable Ingress + enable HTTPRoute in a single commit
3. **Always copy TLS secrets before cutover** -- cert-manager can't reach Envoy before DNS switches
4. **Test everything in dev first** -- always

## Top Gotchas (Preview)

See [docs/gotchas.md](docs/gotchas.md) for the full list with detailed fixes.

1. **Envoy rejects headers with underscores** -- nginx allows them by default. ClientTrafficPolicy `withUnderscoresAction: Allow` is mandatory.
2. **Gateway `allowedRoutes` defaults to `from: Same`** -- HTTPRoutes in app namespaces won't attach. Set `from: All`.
3. **`BackendTrafficPolicy.spec.sessionPersistence` doesn't exist** -- Use `spec.loadBalancer.consistentHash.cookie` instead.
4. **cert-manager `featureGates` is deprecated** -- Use `config.enableGatewayAPI: true` in Helm values.
5. **SecurityPolicy `extAuth` strips Location headers** -- Breaks oauth2-proxy browser redirects. Use reverse proxy pattern instead.

## Configuration

Copy `migration.config.example.yaml` to `migration.config.yaml` and customize:

```yaml
project:
  envoy_gateway_version: "v1.7.0"
clusters:
  - name: "my-cluster"
    tier: "dev"
    cloud: "aws"       # aws | azure | gcp | on-prem
repos:
  infrastructure: "/path/to/gitops-repo"
  helm_charts: "/path/to/helm-charts"
gitops:
  tool: "argocd"       # argocd | flux | none
dns:
  provider: "cloudflare"
  proxied: false
tls:
  provider: "cert-manager"
  issuer_name: "letsencrypt-prod"
auth:
  oauth2_proxy: false
  basic_auth_apps: []
```

Agents and skills read this config at session start. CLAUDE.md stays updatable from upstream without merge conflicts.

## Cloud Support

This guide is cloud-agnostic. Tested patterns work on:

- **AWS EKS** -- Route53, ACM, ECR
- **Azure AKS** -- Cloudflare/Azure DNS, cert-manager, ACR
- **GCP GKE** -- Cloud DNS, cert-manager, GCR
- **On-premises** -- Any DNS provider, cert-manager

Cloud-specific details are handled through `migration.config.yaml` settings.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Gotcha reports and cloud-specific additions are especially welcome.

## License

[Apache License 2.0](LICENSE)
