#!/usr/bin/env bash
# Runs every automated check for the project. Requires rojo, lune and selene on PATH
# (see aftman.toml). The Roblox API check runs when API-Dump.json is present (see README).
set -euo pipefail
cd "$(dirname "$0")/.."

step() { printf '\n== %s\n' "$1"; }

step "Compile every .luau file"
lune run tests/compile_check.luau

step "Scenario tests A-J"
lune run tests/run.luau

step "Lint (selene)"
if [ -f roblox.yml ]; then
	selene src tests
else
	echo "roblox.yml missing: run 'selene generate-roblox-std' first"; exit 1
fi

step "Build the place with Rojo"
mkdir -p build
rojo build default.project.json -o build/IronThrone.rbxl

step "Inspect the built place and load every ModuleScript"
lune run tests/place_check.luau build/IronThrone.rbxl

step "Headless UI smoke test (real client code against the real server pipeline)"
lune run tests/ui_smoke.luau build/IronThrone.rbxl

if [ -f build/API-Dump.json ]; then
	step "Roblox API usage check"
	python3 tools/check_roblox_api.py --dump build/API-Dump.json src
else
	printf '\n(skipping the Roblox API check: download build/API-Dump.json as described in README.md)\n'
fi

printf '\nAll checks passed.\n'
