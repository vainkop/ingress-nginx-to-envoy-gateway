.PHONY: lint validate security-scan test

# Run all linters
lint:
	@echo "==> Running yamllint..."
	yamllint -c .yamllint.yaml .
	@echo "==> Running markdownlint..."
	markdownlint-cli2 "**/*.md" "#node_modules"
	@echo "==> Running shellcheck..."
	shellcheck scripts/*.sh
	@echo "==> All linters passed"

# Validate all example YAML with kubeconform
validate:
	@echo "==> Validating Kubernetes YAML examples..."
	find examples/ -name '*.yaml' -not -path '*/helm-values/*' -print0 | xargs -0 ./scripts/validate-yaml.sh
	@echo "==> All examples validated"

# Run security scanning
security-scan:
	@echo "==> Running gitleaks..."
	gitleaks detect --source . --no-git
	@echo "==> Running checkov on examples..."
	checkov -d examples/ --framework kubernetes --skip-check CKV_K8S_43 --compact
	@echo "==> Security scan passed"

# Run everything
test: lint validate security-scan
	@echo "==> All checks passed"
