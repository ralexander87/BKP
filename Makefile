SHELL := bash

SCRIPTS := bkp-main.sh restore-main.sh bkp-serv.sh restore-serv.sh restore-dots.sh lib/common.sh lib/restore-bootstrap.sh doctor.sh tools/sync-restore-bootstrap.sh tools/smoke.sh

.PHONY: check deps list syntax fmt-check ci-check bootstrap-check smoke doctor

check:
	@command -v shellcheck >/dev/null || { echo "missing: shellcheck"; exit 1; }
	@shellcheck $(SCRIPTS)

syntax:
	@bash -n $(SCRIPTS)

fmt-check:
	@command -v shfmt >/dev/null || { echo "missing: shfmt"; exit 1; }
	@shfmt -d $(SCRIPTS)

bootstrap-check:
	@tools/sync-restore-bootstrap.sh check

smoke: bootstrap-check syntax
	@tools/smoke.sh

doctor:
	@./doctor.sh

ci-check: syntax check fmt-check bootstrap-check smoke

deps:
	@command -v rsync >/dev/null || { echo "missing: rsync"; exit 1; }
	@command -v pigz >/dev/null || echo "optional missing: pigz"
	@command -v shellcheck >/dev/null || { echo "missing: shellcheck"; exit 1; }
	@command -v shfmt >/dev/null || echo "optional missing: shfmt"

list:
	@printf '%s\n' $(SCRIPTS)
