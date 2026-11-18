SHELL := /bin/bash

.PHONY: build check docs-list format lint quality-gate release restart start start-debug start-release stop test test-live test-tty

start:
	./Scripts/compile_and_run.sh

start-debug:
	./Scripts/compile_and_run.sh

start-release:
	./Scripts/package_relay_app.sh release
	./Scripts/launch.sh

restart: start

stop:
	./Scripts/stop_headroom.sh

check lint:
	./Scripts/lint.sh lint

format:
	./Scripts/lint.sh format

docs-list:
	node Scripts/docs-list.mjs

build:
	swift build

test:
	./Scripts/test.sh

quality-gate:
	./Scripts/quality_gate.py

test-tty:
	./Scripts/test.sh --filter TTYIntegrationTests

test-live:
	LIVE_TEST=1 ./Scripts/test.sh --filter LiveAccountTests

release:
	./Scripts/package_relay_app.sh release
