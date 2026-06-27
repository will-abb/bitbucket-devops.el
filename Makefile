EMACS ?= emacs
INTEGRATION_EMACS_PACKAGE_DIRECTORY ?=
INTEGRATION_TEST_AUTH_SOURCE_HOST ?= bitbucket-devops-williseed1-test
INTEGRATION_EMACS_PACKAGE_ENV = $(if $(strip $(INTEGRATION_EMACS_PACKAGE_DIRECTORY)),BITBUCKET_DEVOPS_TEST_EMACS_PACKAGE_DIRECTORY=$(INTEGRATION_EMACS_PACKAGE_DIRECTORY),)
INTEGRATION_TEST_ENV = BITBUCKET_DEVOPS_TEST_AUTH_SOURCE_HOST=$(INTEGRATION_TEST_AUTH_SOURCE_HOST)

.PHONY: test integration-test integration-mutation-test compile lint load-test

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
			bitbucket-devops-pull-requests-ui.el \
			bitbucket-devops.el

lint:
	$(EMACS) -Q --batch -l package --eval "(package-initialize)" \
		-L . -l package-lint \
		-f package-lint-batch-and-exit bitbucket-devops.el

load-test:
	$(EMACS) -Q --batch -L . --eval \
		"(progn (require 'package) (package-initialize) (require 'bitbucket-devops))"
