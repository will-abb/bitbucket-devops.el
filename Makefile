EMACS ?= emacs
INTEGRATION_EMACS_PACKAGE_DIRECTORY ?=
INTEGRATION_TEST_AUTH_SOURCE_HOST ?= bitbucket-devops-williseed1
INTEGRATION_EMACS_PACKAGE_ENV = $(if $(strip $(INTEGRATION_EMACS_PACKAGE_DIRECTORY)),BITBUCKET_DEVOPS_TEST_EMACS_PACKAGE_DIRECTORY=$(INTEGRATION_EMACS_PACKAGE_DIRECTORY),)
INTEGRATION_TEST_ENV = BITBUCKET_DEVOPS_TEST_AUTH_SOURCE_HOST=$(INTEGRATION_TEST_AUTH_SOURCE_HOST)

.PHONY: test integration-test integration-mutation-test compile lint checkdoc load-test clean

test:
	$(EMACS) -Q --batch -l package --eval "(package-initialize)" \
		-L . -L test -l test/run-tests.el

integration-test:
	$(INTEGRATION_TEST_ENV) $(INTEGRATION_EMACS_PACKAGE_ENV) $(EMACS) -Q --batch -L . -L test/integration \
		-l test/integration/run-tests.el

integration-mutation-test:
	BITBUCKET_DEVOPS_TEST_MUTATIONS=1 $(INTEGRATION_TEST_ENV) $(INTEGRATION_EMACS_PACKAGE_ENV) $(EMACS) \
		-Q --batch -L . -L test/integration \
		-l test/integration/run-tests.el

compile:
	$(EMACS) -Q --batch -l package --eval "(package-initialize)" \
		-L . -f batch-byte-compile \
			bitbucket-devops-context.el \
			bitbucket-devops-cache.el \
			bitbucket-devops-rest.el \
			bitbucket-devops-ui.el \
			bitbucket-devops-pipelines-watch.el \
			bitbucket-devops-pipelines-magit.el \
			bitbucket-devops-pipelines-yaml.el \
			bitbucket-devops-pipelines-mutate.el \
			bitbucket-devops-pull-requests.el \
			bitbucket-devops-pull-requests-rest.el \
			bitbucket-devops-pull-requests-watch.el \
			bitbucket-devops-pull-requests-ui.el \
			bitbucket-devops.el

# package-lint must know the main file, otherwise every secondary library is
# linted as if it were a package of its own and reports spurious dependency
# errors.  Must report no errors and no warnings.
lint:
	$(EMACS) -Q --batch -l package --eval "(package-initialize)" \
		-L . -l package-lint \
		--eval '(setq package-lint-main-file "bitbucket-devops.el")' \
		-f package-lint-batch-and-exit *.el

# The experimental voice check is disabled: it reports argument names such as
# STEPS and UPDATES, and the Bitbucket term "request changes", as misconjugated
# verbs.  Every other checkdoc convention is enforced and must stay clean.
checkdoc:
	$(EMACS) -Q --batch -l package --eval "(package-initialize)" -L . \
		--eval "(progn (require 'checkdoc) \
			(setq checkdoc-verb-check-experimental-flag nil) \
			(dolist (f (file-expand-wildcards \"*.el\")) (checkdoc-file f)) \
			(with-current-buffer (get-buffer-create \"*Warnings*\") \
			  (when (> (buffer-size) 0) (kill-emacs 1))))"

load-test:
	$(EMACS) -Q --batch -L . --eval \
		"(progn (require 'package) (package-initialize) (require 'bitbucket-devops))"

# `compile' leaves .elc files behind, and Emacs loads those in preference to
# the sources.  Run this to force a subsequent `test' back onto plain .el.
clean:
	rm -f *.elc test/*.elc test/integration/*.elc
