# bitbucket-devops.el

`bitbucket-devops.el` brings the Bitbucket Cloud workflows a DevOps engineer
uses every day into Emacs: Pipelines and pull requests.

- **Pipelines** — repository-aware history and details, completed step logs,
  watcher notifications, manual triggers driven by `bitbucket-pipelines.yml`,
  manual-step continuation, reruns, and cancellation.
- **Pull requests** — listing and filtering, build summaries, comments and
  activity, commits, changed-file summaries, raw diff buffers, review actions,
  reviewer management, inline comments and replies, creation, merge, and
  decline.

Bitbucket Cloud only. Bitbucket Data Center is not supported.

[![Watch the bitbucket-devops.el demo video](https://img.youtube.com/vi/jSwK5WlVZrg/hqdefault.jpg)](https://youtu.be/jSwK5WlVZrg)

## Requirements

- Emacs 29.1 or newer
- Magit 4.0.0 or newer
- `markdown-mode` 2.6 or newer
- `transient` 0.3.0 or newer
- `yaml` 1.2.3 or newer from GNU ELPA
- A Bitbucket Cloud repository with Pipelines enabled
- An SSH Git remote, such as `git@bitbucket.org:workspace/repository.git`

## Installation

With Emacs 29.1 or newer, `package-vc-install` can install directly from GitHub:

```elisp
(package-vc-install
 '(bitbucket-devops
   :url "https://github.com/will-abb/bitbucket-devops.el.git"
   :branch "main"))
```

Or clone the repository and put it on your load path:

```sh
git clone https://github.com/will-abb/bitbucket-devops.el.git
```

```elisp
(add-to-list 'load-path "/path/to/bitbucket-devops.el")
(require 'bitbucket-devops)
```

With Doom Emacs, add the package to `packages.el` and run `doom sync`:

```elisp
(package! bitbucket-devops
  :recipe (:host github
           :repo "will-abb/bitbucket-devops.el"
           :files ("*.el")))
```

The package does not install Magit key bindings. Bind the transient dispatch in
your own configuration if desired:

```elisp
(global-set-key (kbd "C-c b") #'bitbucket-devops-dispatch)
```

## Setup

Store a scoped Bitbucket Cloud token in `.authinfo.gpg`. App Passwords are not
supported.

```text
machine bitbucket-devops-williseed1 login x-token-auth password ACCESS_TOKEN
```

Point the package at that credential:

```elisp
(setq bitbucket-devops-auth-rules
      '((:workspace "williseed1"
         :auth-source-host "bitbucket-devops-williseed1")))
```

Grant the token Pipelines `Read` and Pull Requests `Read` to browse, and add the
matching `Write` permissions to trigger runs or act on pull requests. Credential
selection fails closed: if no rule matches the current repository, the command
reports an error instead of falling back.

See [Authentication](DOCUMENTATION.md#authentication) for token types, the full
permission matrix, and per-repository rules.

## Usage

Run `M-x bitbucket-devops-dispatch` from any buffer inside a Bitbucket
repository for the unified Pipelines and pull request menu.

| Key | Command |
| --- | --- |
| `h` | Show pipeline history |
| `l` | Show pull requests |
| `c` | Create a pull request |
| `r` | Run a configured pipeline for the current branch |
| `b` / `o` | Watch new pipelines on a branch or in the repository |
| `t` | List active watchers |

Press `?` in any package buffer to toggle a panel listing the keys available on
that screen.

## Documentation

[DOCUMENTATION.md](DOCUMENTATION.md) covers everything else:

- [Authentication](DOCUMENTATION.md#authentication) — token types, scopes, and
  multi-repository auth rules
- [Commands and keybindings](DOCUMENTATION.md#commands-and-keybindings) — every
  binding in every buffer, and how to rebind them
- [Pull requests](DOCUMENTATION.md#pull-requests) — reviewers, inline comments,
  checks, diff viewers, and comment watchers
- [Pipelines](DOCUMENTATION.md#pipelines) — triggers, manual steps, logs,
  watchers, notifications, and Magit push tracking
- [Caching](DOCUMENTATION.md#caching) — what is cached and how refreshes
  revalidate it
- [Customization variables](DOCUMENTATION.md#customization-variables) — the full
  `defcustom` reference
- [Development](DOCUMENTATION.md#development) — test suites and contributor
  setup

`bitbucket-devops-specification.md` documents the package contract.

If you would rather ask a question than read a reference, the
[Bitbucket DevOps for Emacs Helper](https://chatgpt.com/g/g-6a3ffd3d8bcc8191bb75c20f0121dee0-bitbucket-devops-for-emacs-helper)
is a custom GPT set up to answer questions about this package. The
[demo video](https://youtu.be/jSwK5WlVZrg) is a usage walkthrough rather than a
setup guide.

## License

`bitbucket-devops.el` is released under the GNU General Public License v3.0.
See `LICENSE`.
