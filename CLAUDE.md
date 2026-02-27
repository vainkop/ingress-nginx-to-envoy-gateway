# ingress-nginx to Envoy Gateway Migration

You are a DevOps engineer migrating Kubernetes ingress from ingress-nginx to Envoy Gateway (Gateway API).

## Configuration

- Read `migration.config.yaml` for all environment-specific values (clusters, repos, DNS, TLS, auth).
- If the file does not exist, prompt the user to run: `cp migration.config.example.yaml migration.config.yaml`
- NEVER hardcode cluster names, repo paths, hostnames, IPs, or app names. Always read from config.
- Config keys referenced throughout this document:
  - `config.clusters[]` -- cluster names, tiers, cloud providers, kubectl contexts
  - `config.repos.infrastructure` -- GitOps infra repo path
  - `config.repos.helm_charts` -- shared Helm charts repo path
  - `config.repos.standalone_apps[]` -- apps with their own repos and CI/CD
  - `config.dns.provider`, `config.dns.proxied`, `config.dns.external_dns_policy`
  - `config.tls.provider`, `config.tls.issuer_name`, `config.tls.issuer_kind`
  - `config.auth.oauth2_proxy`, `config.auth.basic_auth_apps[]`
  - `config.advanced.node_selector`, `config.advanced.namespace`
- Refer to `docs/` for detailed guides on each topic. Refer to `examples/` for ready-to-apply YAML.

## Envoy Gateway Version

- **Target**: v1.7.0 (compiled against Gateway API v1.4.1)
- Gateway API v1.5.0 exists but is **NOT supported** by Envoy Gateway v1.7.0
- See compatibility matrix: https://gateway.envoyproxy.io/news/releases/matrix/

## Key Constraints

All 22 constraints below are hard-won from production migrations. Violating any one causes outages, silent failures, or hours of debugging.

### Infrastructure

1. **Separate LoadBalancers**: Envoy Gateway must use its own LoadBalancer (new IP). It cannot share with nginx. Both run simultaneously during migration.
2. **DNS manual cleanup**: When `config.dns.external_dns_policy` is `upsert-only`, old DNS records pointing to the nginx LB IP will NOT auto-delete when Ingress resources are removed. Stale records must be manually cleaned from your DNS provider after cutover.
3. **CDN/proxy-aware migration**: When `config.dns.proxied` is `true` (e.g., Cloudflare proxy, CloudFront), origin IP changes are transparent to end users. However, the CDN may apply its own TLS/SSL settings that interact with cert-manager. If debugging origin connection issues, check CDN-level TLS configuration rules, not just zone settings.
4. **Node architecture**: Set `nodeSelector` matching `config.advanced.node_selector` on all Envoy Gateway controller and proxy pods. If using a node autoscaler with custom taints (CAST.ai, Karpenter), Envoy pods need untainted general-purpose nodes.

### Auth Patterns (CRITICAL)

5. **DO NOT use SecurityPolicy extAuth with oauth2-proxy**: Envoy strips `Location` headers from auth subrequest responses, breaking browser login redirects entirely. Instead, route traffic directly to oauth2-proxy as a **reverse proxy** (oauth2-proxy forwards to the upstream app via `OAUTH2_PROXY_UPSTREAMS`). This is a fundamental Envoy behavior, not a bug.
6. **Auth migration is two-part**: For each auth-protected app, BOTH the oauth2-proxy HTTPRoute AND the app HTTPRoute must be migrated together to the same Gateway hostname. The oauth2-proxy serves `/oauth2/*` via its own HTTPRoute, and traffic to the app flows through oauth2-proxy as reverse proxy.
7. **SecurityPolicy basicAuth works fine**: Needs a Secret with a `.htpasswd` key using **SHA hash** (not bcrypt, which Envoy does not support). Use `htpasswd -s` to generate.
8. **Use `targetRefs` (plural list) not deprecated `targetRef` (singular)**: The singular form still works in v1.7.0 but is deprecated and may be removed. Same applies to `backendRefs`.

### cert-manager and TLS

9. **cert-manager Gateway API support**: Must set `config.enableGatewayAPI: true` in cert-manager Helm values. Do NOT use the deprecated `featureGates` approach. After the Helm upgrade creates Gateway API RBAC, cert-manager pods must be **restarted** to pick up the new permissions.
10. **TLS cert chicken-and-egg**: Before DNS cutover, cert-manager http01 challenges cannot reach Envoy (DNS still points to nginx). Workaround: copy the existing TLS Secret from the app namespace to `envoy-gateway-system` (or wherever the Gateway lives). cert-manager auto-renews after DNS switches to Envoy.
11. **Separate ClusterIssuer for Gateway**: Create a second ClusterIssuer (e.g., `letsencrypt-prod-gateway`) that uses `http01.gatewayHTTPRoute` solver instead of `http01.ingress.ingressClassName: nginx`.

### DNS Cutover

12. **DNS cutover must be atomic per hostname**: Set `ingress.enabled: false` AND `gatewayAPI.enabled: true` in a **single commit/deploy**. Never have both Ingress and HTTPRoute active for the same hostname simultaneously -- this causes external-dns to flap the A record between the nginx and Envoy LB IPs.

### Gateway Configuration

13. **Gateway `allowedRoutes` must be `from: All`**: The default is `from: Same`, which only allows HTTPRoutes in the Gateway's own namespace (e.g., `envoy-gateway-system`). App HTTPRoutes live in their own namespaces. Set `allowedRoutes.namespaces.from: All` on ALL Gateway listeners.
14. **Envoy rejects headers with underscores by default**: A `ClientTrafficPolicy` with `headers.withUnderscoresAction: Allow` is **MANDATORY** on every cluster Gateway. Without this, any request containing headers with underscores (common from CDN proxies, server-side API callouts, legacy clients) gets a 400. nginx allows underscores by default. This is a cluster-level setting, not per-app.
15. **Always include `%RESPONSE_CODE_DETAILS%` in Envoy access logs**: This field shows exactly why Envoy rejected a request (e.g., `http1.unexpected_underscore`, `filter_chain_not_found`). Without it, debugging proxy-level 400/404 errors is nearly impossible. Configure in the `EnvoyProxy` telemetry config.

### Envoy Gateway v1.7.0 CRD Reality

16. **`BackendTrafficPolicy.spec.sessionPersistence` does NOT exist**: Use `spec.loadBalancer.consistentHash.cookie` instead for cookie-based session affinity.
17. **`ClientTrafficPolicy.spec.clientRequestBody` does NOT exist**: Use `BackendTrafficPolicy.spec.requestBuffer.limit` (type `resource.Quantity`, e.g., `"10Mi"`) instead.
18. **No ClientTrafficPolicy needed for most apps**: Unless you need to configure HTTP/2, TLS termination settings, or the underscore header fix (constraint 14).

### Helm Chart Strategy

19. **Never set `gatewayAPI.enabled: true` in root values.yaml**: Only set it in env-specific values files (e.g., `dev-values.yaml`) to limit blast radius to one cluster at a time.
20. **Library charts are shared and unversioned**: Changes to shared library chart templates affect all clusters immediately. Gate new templates on `role: web` AND `gatewayAPI.enabled`. Always run `helm lint` + `helm template` + `kubeconform` before committing.
21. **Standalone charts are safer**: Charts with their own `templates/ingress.yaml` can be modified individually without cross-cluster risk. Start migration with these.

### Migration Order and DR

22. **Migration order**: Always follow `dev -> staging -> prod`. For DR/standby clusters that share hostnames with a primary, migrate the primary first, then update DR values files so failover is ready. Shared hostnames between active/hibernated clusters are NOT a DNS flapping risk since only one is active at a time.

## Migration Phases

### Phase 0: Infrastructure Setup
Deploy Envoy Gateway alongside nginx (separate LoadBalancer, new IP). Both run concurrently.
Includes: GatewayClass, EnvoyProxy, Gateway with underscore header fix, ClientTrafficPolicy,
cert-manager Gateway ClusterIssuer, access log format with `%RESPONSE_CODE_DETAILS%`.
Use `/setup-cluster` skill.

### Phase 1: Migrate Dev Apps
Start with simple apps (no auth, no WebSocket, no session affinity). Build confidence with
the atomic DNS cutover pattern. Validate each app with `/validate-migration`.

### Phase 2: Migrate Staging Apps
Migrate all apps including complex ones (auth, WebSocket, session affinity). This is where
auth patterns and edge cases get proven before production.

### Phase 3: Migrate Production Apps
Same patterns proven in dev/staging. Extra care with rollback procedures and traffic monitoring.
For clusters with different deploy methods (CI/CD vs GitOps), changes go in different repos --
check `config.repos.standalone_apps[]` for apps outside the main GitOps flow.
After migrating primary clusters, update DR cluster values files.

### Phase 4: Decommission nginx
Scale down nginx replicas (do not delete yet). Monitor for any remaining traffic hitting the
nginx LB IP. Clean up stale DNS records. After a soak period, remove nginx entirely.
See `docs/decommission-nginx.md`.

## Working Conventions

- Always read `migration.config.yaml` at session start for repo paths, cluster names, and settings
- Check `README.md` for current migration status before starting work
- Update tracking (README or migration status) after completing any phase
- When modifying Helm charts, maintain backward compatibility (`gatewayAPI.enabled: false` as default)
- When modifying GitOps repos, follow existing patterns (Kustomization + HelmRelease for Flux; Application/ApplicationSet for ArgoCD)
- For standalone apps (`config.repos.standalone_apps[]`): ingress changes go in their repo, not the GitOps repo
- For system apps (upstream charts like dashboards, monitoring): create standalone HTTPRoute YAML in the GitOps repo
- **Test in dev cluster first, always**
- Never force-push, never skip pre-commit hooks
- Use observability tools (groundcover, Datadog, Prometheus) to inspect live cluster state when available
- When debugging 400/404 errors after migration, FIRST check Envoy access logs for `%RESPONSE_CODE_DETAILS%`

## Skills Available

| Skill | Purpose |
|-------|---------|
| `/setup-cluster` | Deploy Envoy Gateway and configure cluster prerequisites (6-step checklist) |
| `/analyze-ingress` | Parse a live Ingress resource and classify migration complexity |
| `/generate-httproute` | Generate ready-to-apply HTTPRoute + policy YAML from an Ingress |
| `/pre-flight-check` | Verify all cluster prerequisites before migration |
| `/migrate-app` | Step-by-step workflow for migrating a single app from Ingress to HTTPRoute |
| `/validate-migration` | Post-migration validation checklist runner |

## Agents Available

Agents form a pipeline: **audit -> research -> plan -> review -> (approve) -> execute -> validate**

| Agent | Purpose |
|-------|---------|
| `cluster-auditor` | Full cluster readiness assessment, app inventory, risk analysis, shared hostname detection |
| `migration-researcher` | Deep-dive into a specific app's ingress configuration across repos and live cluster |
| `migration-planner` | Produces concrete, reviewable migration plan with exact file paths and diffs. Does NOT execute. |
| `plan-reviewer` | Adversarial review of migration plans against 22+ known failure modes |

### Agent Guidance

- Agents read `migration.config.yaml` for all environment context
- The `cluster-auditor` should be run FIRST before starting any cluster's migration
- The `plan-reviewer` must be run BEFORE executing any plan -- it catches CRD field errors, auth pattern mistakes, and environment-specific safety issues
- Lessons from dev/staging are treated as evidence ("proven on dev") not guarantees ("works on prod")
- For prod clusters: extra scrutiny on shared hostname coordination, rollback procedures, traffic volume awareness, and deployment method differences (GitOps vs CI/CD)

## Recommended Workflow

1. **Configure**: Ensure `migration.config.yaml` exists and is populated for your environment
2. **Pre-flight**: Use `/pre-flight-check` to verify cluster prerequisites (CRDs, cert-manager, Gateway)
3. **Audit the cluster**: Run `cluster-auditor` for full cluster state and risk assessment
4. **Research each app**: Run `migration-researcher` for per-app deep dive (optional if auditor gives enough detail)
5. **Plan the migration**: Run `migration-planner` to produce a reviewable plan with exact changes
6. **Review the plan**: Run `plan-reviewer` to check the plan against 22+ known failure modes
7. **Execute**: Use `/migrate-app` skill to implement the approved plan
8. **Validate**: Use `/validate-migration` skill to verify everything works
9. **Track**: Update migration status tracking
10. **Repeat**: Move to the next cluster tier (dev -> staging -> prod)

## Reference Documentation

| Document | Path |
|----------|------|
| Battle-tested gotchas (15+) | `docs/gotchas.md` |
| Auth migration patterns | `docs/auth-migration-patterns.md` |
| DNS cutover strategy | `docs/dns-cutover-strategy.md` |
| cert-manager + Gateway API | `docs/cert-manager-gateway-setup.md` |
| Envoy Gateway v1.7.0 CRD reference | `docs/envoy-gateway-v1.7-crd-reference.md` |
| Debugging underscore headers | `docs/debugging-underscore-headers.md` |
| Helm template strategy | `docs/helm-template-strategy.md` |
| Decommission nginx | `docs/decommission-nginx.md` |

## Rollback Procedure

If a migrated app has issues after DNS cutover:

1. Set `gatewayAPI.enabled: false` and `ingress.enabled: true` in the same commit/deploy
2. DNS will switch back to the nginx LB IP via external-dns
3. If `external_dns_policy` is `upsert-only`, the old nginx A record may already be gone -- manually re-add it
4. The TLS secret copied to `envoy-gateway-system` can be left in place (harmless)
5. nginx must still be running (this is why Phase 4 scales down but does not delete)

## Example YAML

Ready-to-use templates in `examples/` with `# REPLACE:` comments:

- `examples/gateway/` -- GatewayClass, EnvoyProxy, Gateway, ClientTrafficPolicy, ClusterIssuer
- `examples/httproute/` -- Simple, BackendTrafficPolicy, WebSocket, session affinity, basic auth, oauth2-proxy, system apps
- `examples/helm-values/` -- Helm values for different app complexity levels
- `examples/flux/` -- HelmRelease and Kustomization patterns
- `examples/argocd/` -- ApplicationSet with gateway override values

## Quick Reference: nginx Annotation to Envoy Gateway Mapping

| nginx Annotation | Envoy Gateway Equivalent |
|------------------|--------------------------|
| `proxy-body-size` | `BackendTrafficPolicy.spec.requestBuffer.limit` |
| `proxy-read-timeout` / `proxy-send-timeout` | `BackendTrafficPolicy.spec.timeout.http.requestTimeout` |
| `proxy-connect-timeout` | `BackendTrafficPolicy.spec.timeout.tcp.connectTimeout` |
| `proxy-next-upstream` / `tries` | `BackendTrafficPolicy.spec.retry` (numRetries = nginx tries - 1) |
| `session-cookie-*` | `BackendTrafficPolicy.spec.loadBalancer.consistentHash.cookie` |
| `auth-url` / `auth-signin` | **DO NOT use SecurityPolicy extAuth** -- use reverse proxy pattern |
| `auth-type: basic` | `SecurityPolicy.spec.basicAuth` with `.htpasswd` Secret |
| `whitelist-source-range` | `SecurityPolicy.spec.authorization` (defaultAction: Deny + Allow rules) |
| `denylist-source-range` | `SecurityPolicy.spec.authorization` (defaultAction: Allow + Deny rules) |
| `websocket-services` | No annotation needed -- Envoy handles WebSocket upgrade by default |
| `ssl-redirect` | Gateway listener with `tls.mode: Terminate` handles this automatically |
| `rewrite-target` | HTTPRoute `URLRewrite` filter or `HTTPRouteFilter` CRD for regex |
| `backend-protocol: GRPC` | `GRPCRoute` instead of HTTPRoute |
| `ssl-passthrough` | `TLSRoute` with Gateway TLS Passthrough listener (experimental CRDs) |
| `proxy-ssl-*` | `BackendTLSPolicy` or Envoy Gateway `Backend` CRD for mTLS |
| `x-forwarded-prefix` | HTTPRoute `RequestHeaderModifier` filter |
| `upstream-vhost` | HTTPRoute `URLRewrite` filter (hostname only) |
| `proxy-buffer-size` | `BackendTrafficPolicy.spec.responseOverride` (or EnvoyProxy config) |
| `cors-*` | `SecurityPolicy.spec.cors` |
| `rate-limit-*` | `BackendTrafficPolicy.spec.rateLimit` |
