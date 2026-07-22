.PHONY: app test test-python test-swift lint typecheck spdx check hooks

app: ## Build dist/Tamlil.app (ad-hoc signed)
	cd Tamlil && ./build.sh

test-python:
	uv run pytest -q

# No Xcode on dev machines (CLT only), so XCTest is unavailable; the app
# embeds its own assertion harness instead.
test-swift:
	cd Tamlil && swift run Tamlil --self-check

lint:
	uv run ruff check .
	uv run ruff format --check .

typecheck:
	uv run mypy src

spdx: ## Every first-party source carries an Apache-2.0 SPDX header
	scripts/check-spdx.sh

test: test-python test-swift

check: lint typecheck spdx test

hooks: ## One-time per clone: run lint + tests before every push
	git config core.hooksPath .githooks
