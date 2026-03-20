.PHONY: check lint format lint-ts lint-py format-ts format-py docs docs-strict docs-live docs-clean persistent-up persistent-down persistent-logs persistent-status persistent-connect persistent-dashboard-url

check: lint-ts lint-py
	@echo "All checks passed."

lint: lint-ts lint-py

lint-ts:
	cd nemoclaw && npm run check

lint-py:
	cd nemoclaw-blueprint && $(MAKE) check

format: format-ts format-py

format-ts:
	cd nemoclaw && npm run lint:fix && npm run format

format-py:
	cd nemoclaw-blueprint && $(MAKE) format

# --- Documentation ---

docs:
	uv run --group docs sphinx-build -b html docs docs/_build/html

docs-strict:
	uv run --group docs sphinx-build -W -b html docs docs/_build/html

docs-live:
	uv run --group docs sphinx-autobuild docs docs/_build/html --open-browser

docs-clean:
	rm -rf docs/_build

# --- Persistent Control Plane ---

persistent-up:
	docker compose -f compose.persistent.yaml up -d --build

persistent-down:
	docker compose -f compose.persistent.yaml down

persistent-logs:
	docker logs -f nemoclaw-control

persistent-status:
	docker compose -f compose.persistent.yaml exec nemoclaw-control nemoclaw status

persistent-connect:
	docker compose -f compose.persistent.yaml exec nemoclaw-control bash -lc 'name=$$(python3 -c "import json; from pathlib import Path; p = Path.home() / \".nemoclaw\" / \"sandboxes.json\"; data = json.loads(p.read_text()); print(data.get(\"defaultSandbox\", \"\"))"); test -n "$$name" && nemoclaw "$$name" connect'

persistent-dashboard-url:
	@echo http://127.0.0.1:$${NEMOCLAW_REDIRECT_PORT:-18788}/
