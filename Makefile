.PHONY: help validate lint format test

help:
	@printf '%s\n' \
		'Targets:' \
		'  make validate  Run bash syntax checks, optional linters, and regression tests' \
		'  make lint      Treat optional linter findings as failures' \
		'  make format    Format shell scripts with shfmt (requires shfmt)' \
		'  make test      Run regression tests'

validate:
	bash scripts/validate.sh
	bash scripts/test.sh

test:
	bash scripts/test.sh

lint:
	bash scripts/validate.sh --strict

format:
	shfmt -w $$(find . -maxdepth 2 -type f -name '*.sh' ! -path './.git/*' | sort)
