# Security Policy

This is a learning/portfolio project, but it is built to production security
standards and treated as if it were shipping.

## Reporting a vulnerability

If you find a security issue, please **do not open a public issue**. Instead,
report it privately via GitHub's [private vulnerability reporting](https://docs.github.com/en/code-security/security-advisories/guidance-on-reporting-and-writing-information-about-vulnerabilities/privately-reporting-a-security-vulnerability)
("Report a vulnerability" under the repository's **Security** tab), or email the
maintainer. You'll get an acknowledgement within a few days.

## Security model

The design assumes a breach *will* happen and limits its blast radius. The full
threat model — every control mapped to the attack it defeats, plus a post-RCE
kill-chain walkthrough — lives in the [README](README.md#why-the-hardening-matters--the-attackers-perspective).

Highlights:

- **Network segmentation** — a data tier (`postgres`/`redis`) that is unreachable
  from the host and from the edge proxy; only the API tier can reach it.
- **Container hardening** — every workload runs non-root, drops all Linux
  capabilities, disallows privilege escalation, uses a read-only root filesystem,
  and runs under the default seccomp profile.
- **Kubernetes** — Pod Security Admission (`restricted`), zero-trust
  NetworkPolicies (default-deny), and ServiceAccounts with token automount off.
- **Supply chain** — base images pinned by digest; CI scans every image for CVEs
  (Trivy), lints the Dockerfile (hadolint), scans the git history for secrets
  (gitleaks), and scans the manifests for misconfigurations (Trivy config).

## Verifying the controls

The controls are not just asserted — they are checked:

```bash
make compose-up
make verify-isolation      # asserts isolation & hardening on the live stack
```

CI additionally runs schema validation and the full security scan suite on every
push and pull request (see `.github/workflows/`).

## Known, accepted exceptions

Triaged security-scan exceptions are documented with justifications in
[`.trivyignore`](.trivyignore) — e.g. the database container cannot use a
read-only root filesystem because its engine must write to its data directory.
