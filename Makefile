SCRIPTS := lib/common.sh scripts/backup-verify.sh scripts/healthcheck.sh scripts/log-rotate-check.sh

.PHONY: test lint syntax check install-hooks

check: lint syntax test ## Everything CI runs

test: ## Run the bats suite
	bats --print-output-on-failure tests/

lint: ## shellcheck, following sourced files, style severity
	shellcheck -x --severity=style $(SCRIPTS)

syntax: ## Parse every script without executing it
	@for script in $(SCRIPTS); do bash -n "$$script" && echo "ok  $$script"; done

install-hooks: ## Run lint + syntax before every commit
	@printf '#!/bin/sh\nmake lint syntax\n' > .git/hooks/pre-commit
	@chmod +x .git/hooks/pre-commit
	@echo "installed .git/hooks/pre-commit"
