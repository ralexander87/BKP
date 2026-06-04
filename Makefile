SHELL := bash

SCRIPTS := bkp-main.sh restore-main.sh bkp-serv.sh restore-serv.sh restore-dots.sh lib/common.sh

.PHONY: check deps list

check:
	@command -v shellcheck >/dev/null || { echo "missing: shellcheck"; exit 1; }
	@shellcheck $(SCRIPTS)

deps:
	@command -v rsync >/dev/null || { echo "missing: rsync"; exit 1; }
	@command -v pigz >/dev/null || echo "optional missing: pigz"
	@command -v shellcheck >/dev/null || { echo "missing: shellcheck"; exit 1; }
	@command -v shfmt >/dev/null || echo "optional missing: shfmt"

list:
	@printf '%s\n' $(SCRIPTS)
