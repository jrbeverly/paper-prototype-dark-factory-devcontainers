.DEFAULT_GOAL := help

.PHONY: help run

help: ## Show available make targets
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-12s %s\n", $$1, $$2}'

run: ## Execute the task pipeline  (TASK="<prompt>" required, REPO="<url>" optional)
	TASK="$(TASK)" REPO="$(REPO)" bash factory/run.sh
