SHELL := /bin/bash

.PHONY: install-deps

install-deps:
	@echo "── checking dependencies ──"
	@if command -v pixi >/dev/null 2>&1; then \
		echo "pixi: already installed ($$(pixi --version))"; \
	else \
		echo "pixi: not found — installing ..."; \
		curl -fsSL https://pixi.sh/install.sh | bash; \
	fi
	@if command -v docker >/dev/null 2>&1; then \
		echo "container runtime: docker ($$(docker --version))"; \
	elif command -v podman >/dev/null 2>&1; then \
		echo "container runtime: podman ($$(podman --version))"; \
	else \
		echo "container runtime: not found — installing podman ..."; \
		if command -v apt-get >/dev/null 2>&1; then \
			sudo apt-get update -qq && sudo apt-get install -y -qq podman; \
		elif command -v dnf >/dev/null 2>&1; then \
			sudo dnf install -y podman; \
		elif command -v brew >/dev/null 2>&1; then \
			brew install podman; \
		else \
			echo "error: no supported package manager found — install podman manually" >&2; \
			exit 1; \
		fi; \
	fi
	@if command -v gh >/dev/null 2>&1; then \
		echo "gh cli: already installed ($$(gh --version | head -1))"; \
	else \
		echo "gh cli: not found — installing ..."; \
		if command -v apt-get >/dev/null 2>&1; then \
			sudo mkdir -p /etc/apt/keyrings \
			&& curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
				| sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null \
			&& echo "deb [arch=$$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
				| sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null \
			&& sudo apt-get update -qq && sudo apt-get install -y -qq gh; \
		elif command -v dnf >/dev/null 2>&1; then \
			sudo dnf install -y gh; \
		elif command -v brew >/dev/null 2>&1; then \
			brew install gh; \
		else \
			echo "error: no supported package manager found — install gh manually" >&2; \
			exit 1; \
		fi; \
	fi
	@if command -v k3d >/dev/null 2>&1; then \
		echo "k3d: already installed ($$(k3d version | head -1))"; \
	else \
		echo "k3d: not found — installing ..."; \
		curl -fsSL https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash; \
	fi
	@echo "── all dependencies installed ──"
