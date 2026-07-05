.PHONY: help validate lint format

help:
	@printf '%s\n' \
		'Targets:' \
		'  make validate  Run bash syntax checks and optional linters' \
		'  make lint      Treat optional linter findings as failures' \
		'  make format    Format shell scripts with shfmt'

validate:
	bash scripts/validate.sh

lint:
	bash scripts/validate.sh --strict

format:
	shfmt -w *.sh scripts/*.sh
