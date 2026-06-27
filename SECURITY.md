# Security Policy

## Supported Versions

Security fixes target the current `main` branch until tagged releases are
introduced.

## Reporting a Vulnerability

Please report suspected vulnerabilities through GitHub's private vulnerability
reporting flow for this repository, or contact the maintainer directly if that
flow is unavailable.

Please do not include credentials, tokens, exploit details, or private
repository URLs in public issues. For token exposure, unsafe logging,
credential selection, or authorization bugs, use GitHub private vulnerability
reporting first so the issue can be fixed before details are public.

This package reads Bitbucket credentials from Emacs `auth-source`. Reports
about token exposure, unsafe logging, credential selection, or requests sent to
unexpected hosts are security-relevant.
