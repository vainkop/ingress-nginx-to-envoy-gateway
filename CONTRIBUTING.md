# Contributing

Thank you for your interest in improving this migration guide! Contributions are welcome.

## How to Contribute

### Reporting Issues

- **Gotcha reports**: Found a new migration gotcha? Open an issue with the Symptom, Root Cause, and Fix.
- **Incorrect CRD info**: Envoy Gateway evolves fast. If a CRD field reference is wrong, let us know.
- **Cloud-specific gaps**: Missing guidance for your cloud provider? Tell us what's needed.

### Pull Requests

1. Fork the repo and create a feature branch
2. Run `make test` before submitting (requires pre-commit, kubeconform, helm)
3. Ensure all YAML examples pass validation
4. Update docs if your change affects migration procedures

### Development Setup

```bash
# Install pre-commit
pip install pre-commit
pre-commit install

# Run all checks
make test

# Run specific checks
make lint       # yamllint + markdownlint + shellcheck
make validate   # kubeconform on examples/
make security-scan  # gitleaks + checkov
```

### Content Guidelines

- **No org-specific content**: Examples must use generic placeholders (`your-app`, `your-domain.example.com`)
- **Version-pin CRD references**: Always specify which Envoy Gateway version a field applies to
- **Test your examples**: Run `kubectl apply --dry-run=client` on example YAML (with placeholder substitution)
- **Include symptoms**: When documenting gotchas, always include the user-visible symptom first

### Agent and Skill Contributions

Agents and skills read `migration.config.yaml` for environment-specific values. When modifying:

- Never hardcode cluster names, paths, or domain names
- Reference config values: `{config.repos.helm_charts}`, `{config.clusters[*].name}`, etc.
- Test with `claude` CLI in a repo with `migration.config.yaml` configured

## Code of Conduct

Be respectful, constructive, and helpful. We're all trying to make Kubernetes migrations less painful.

## License

By contributing, you agree that your contributions will be licensed under the Apache License 2.0.
