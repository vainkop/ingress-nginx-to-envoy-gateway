# Standalone HTTPRoute Helm Template

Template for standalone charts (charts with their own `templates/` directory, NOT using a library chart).

## File: `templates/httproute.yaml`

```yaml
{{- if and (hasKey .Values "gatewayAPI") .Values.gatewayAPI.enabled -}}
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: {{ include "<chart>.fullname" . }}
  labels:
    {{- include "<chart>.labels" . | nindent 4 }}
spec:
  parentRefs:
  - name: {{ .Values.gatewayAPI.gatewayName | default "envoy-gateway" }}
    namespace: {{ .Values.gatewayAPI.gatewayNamespace | default "envoy-gateway-system" }}
  hostnames:
  {{- range .Values.ingress.hosts }}
  - {{ .host | quote }}
  {{- end }}
  rules:
  {{- range .Values.ingress.hosts }}
  {{- range .paths }}
  - matches:
    - path:
        type: PathPrefix
        value: {{ .path }}
    backendRefs:
    - name: {{ include "<chart>.fullname" $ }}
      port: {{ $.Values.service.port }}
  {{- end }}
  {{- end }}
{{- end }}
```

Replace `<chart>` with the actual chart name helper prefix (e.g., `my-app`, `my-api`).

## Notes

- The template reuses `ingress.hosts` for hostnames and paths so you do not need to duplicate host configuration.
- `gatewayAPI.gatewayName` and `gatewayAPI.gatewayNamespace` default to `envoy-gateway` and `envoy-gateway-system` respectively.
- The template is gated on `gatewayAPI.enabled` so it produces no output when disabled.
- For apps needing BackendTrafficPolicy (timeouts, body size, session affinity), see `policy-templates.md`.

## Variant: oauth2-proxy Reverse Proxy Pattern

For auth-protected apps, route all traffic through oauth2-proxy instead of to the app directly.
The oauth2-proxy handles authentication and forwards to the app via `OAUTH2_PROXY_UPSTREAMS`.

```yaml
{{- if and (hasKey .Values "gatewayAPI") .Values.gatewayAPI.enabled -}}
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: {{ include "<chart>.fullname" . }}
  labels:
    {{- include "<chart>.labels" . | nindent 4 }}
spec:
  parentRefs:
  - name: {{ .Values.gatewayAPI.gatewayName | default "envoy-gateway" }}
    namespace: {{ .Values.gatewayAPI.gatewayNamespace | default "envoy-gateway-system" }}
  hostnames:
  {{- range .Values.ingress.hosts }}
  - {{ .host | quote }}
  {{- end }}
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /
    backendRefs:
    - name: oauth2-proxy
      port: 4180
{{- end }}
```

In this pattern, the oauth2-proxy deployment must be configured with:
```yaml
OAUTH2_PROXY_UPSTREAMS: "http://<app-service>.<namespace>.svc.cluster.local:<port>"
```

Do NOT use SecurityPolicy extAuth with oauth2-proxy -- Envoy strips Location headers,
breaking browser redirects to the login page. See `annotation-mapping.md` for details.
