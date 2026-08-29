# Changelog

All notable changes to `bitbucket-devops.el` will be documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project uses semantic versioning.

## [Unreleased]

## [3.0.3] - 2026-08-29

### Added

- Added composable pipeline history filters for loaded commit authors, pipeline
  types, and deployment environments.

### Fixed

- Display Bitbucket-reported runner and setup failure metadata above the raw
  step log, including the error key and message, while leaving downloaded logs
  unchanged.

## [3.0.2] - 2026-08-23

### Changed

- Reorganized internal module dependencies into an acyclic stack and removed
  package-internal forward declarations. Cross-feature UI updates now use an
  explicit watcher-change hook and buffer-local command-key callbacks.

## [3.0.1] - 2026-08-09

### Changed

- Renamed the primary transient command to `bitbucket-devops`.
- Defined pipeline mode bindings with their keymaps and initialized optional
  Evil integration from the relevant modes instead of package-load hooks.

### Fixed

- Resolved MELPA review findings from byte compilation, `melpazoid`, and
  `check-declare`, including Custom choice labels, predicate idioms, Savehist
  registration, and external function declarations.

## [3.0.0] - 2026-08-01

### Added

- Added comprehensive setup, authentication, command, customization,
  development, and live-integration documentation.
- Expanded production-like Bitbucket Cloud coverage for authenticated reads,
  pipeline triggers, cancellation, reruns, watchers, deployments, Magit pushes,
  pull requests, and log downloads.

### Changed

- Pipeline trigger and rerun commands no longer prompt for additional free-form
  runtime variables by default. Pass a prefix argument to enter variables that
  `bitbucket-pipelines.yml` does not declare.
- Made GitHub the canonical upstream for MELPA packaging and removed
  repository-hosting files that do not belong in the GitHub project.

### Fixed

- Added complete package metadata, GPL-3.0-only boilerplate, SPDX identifiers,
  maintainer metadata, and MELPA-requested AI assistance attribution.
- Made byte compilation, package-lint, checkdoc, compiled and interpreted ERT,
  pre-commit, isolated installation, and MELPA-style packaging pass cleanly.

### Documentation

- Documented that runtime variables are sent to Bitbucket unsecured, and that
  secrets belong in Bitbucket's own secured variables instead.

## [2.0.0] - 2026-07-04

### Added

- Added pull request comment watchers with quiet baselines, notifications,
  retry backoff, and aggregate mode-line counts.
- Added configured-pipeline shortcuts to pipeline history and pull request
  buffers.

### Changed

- Made pull request refresh, ready/draft, checkout, pipeline, and comment-watch
  keybindings consistent across list and detail buffers.
- Preserved scroll position during pull request and pipeline history refreshes
  and displayed pipeline start times in details.

## [1.0.0] - 2026-06-27

### Added

- Bitbucket Cloud Pipelines history, details, logs, tracking, triggers, reruns,
  manual-step continuation, and cancellation.
- Bitbucket Cloud pull request listing, details, comments, tasks, reviewer
  management, build statuses, diffs, commits, creation, review actions, merge,
  and decline workflows.
- Persistent metadata caching for pipeline and pull request views.
- Offline ERT coverage, opt-in live integration coverage, Bitbucket Pipelines CI,
  pre-commit hooks, secret scanning baseline, and architecture diagram.
- Initial public GitHub release documentation, repository metadata, Doom Emacs
  installation examples, custom GPT helper link, and demo video thumbnail.
- Generated SVG architecture diagram for GitHub README display.
