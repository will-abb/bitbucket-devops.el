# Contributing

Thanks for helping improve `bitbucket-devops.el`.

## Development Setup

Install Emacs 29.1 or newer. The package also needs Magit, `markdown-mode`,
`transient`, and `yaml.el`; the test and lint commands assume those packages
are visible to `emacs -Q` or installed through package.el.

From the repository root:

```sh
make load-test
make test
make compile
make lint
```

`make lint` requires `package-lint`.

## Tests

The default suite is offline and should not require Bitbucket credentials or
network access. Add or update focused ERT coverage for behavior changes.

The integration targets intentionally use the maintainer's dedicated private
Bitbucket Cloud test repository and local checkout. Run them only when that
environment and its auth-source credentials are configured:

```sh
make integration-test
INTEGRATION_EMACS_PACKAGE_DIRECTORY=~/.emacs.d/.local/straight/build-29.3 \
  make integration-mutation-test
```

The mutation target changes remote Bitbucket state and consumes pipeline
minutes.

## Pull Requests

Before opening a pull request:

- Run the offline checks above.
- Keep credentials, tokens, downloaded logs, and local cache files out of the
  repository.
- Document user-facing behavior changes in `README.md`.
- Update `CHANGELOG.md` for notable fixes, features, and breaking changes.
