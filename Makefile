SHELL := /bin/bash

.PHONY: install-deps

install-deps:
	@echo "── checking dependencies ──"
	@if command -v pixi >/dev/null 2>&1; then \
		echo "pixi: already installed ($$(pixi --version))"; \
	else \
		echo "pixi: not found — installing ..."; \
		PIXI_VERSION=0.47.0; \
		curl -fsSL "https://pixi.sh/install.sh" | PIXI_VERSION="$$PIXI_VERSION" bash; \
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
	@if command -v kubectl >/dev/null 2>&1; then \
		echo "kubectl: already installed ($$(kubectl version --client --short 2>/dev/null || kubectl version --client))"; \
	else \
		echo "kubectl: not found — installing ..."; \
		KUBECTL_VERSION=v1.32.4; \
		ARCH=$$(uname -m); \
		case "$$ARCH" in x86_64) ARCH=amd64;; aarch64|arm64) ARCH=arm64;; esac; \
		OS=$$(uname -s | tr '[:upper:]' '[:lower:]'); \
		curl -fsSL -o /tmp/kubectl "https://dl.k8s.io/release/$${KUBECTL_VERSION}/bin/$${OS}/$${ARCH}/kubectl"; \
		curl -fsSL -o /tmp/kubectl.sha256 "https://dl.k8s.io/release/$${KUBECTL_VERSION}/bin/$${OS}/$${ARCH}/kubectl.sha256"; \
		echo "$$(cat /tmp/kubectl.sha256)  /tmp/kubectl" | sha256sum -c; \
		chmod +x /tmp/kubectl; \
		sudo mv /tmp/kubectl /usr/local/bin/kubectl; \
	fi
	@if command -v k3d >/dev/null 2>&1; then \
		echo "k3d: already installed ($$(k3d version | head -1))"; \
	else \
		echo "k3d: not found — installing ..."; \
		TAG=v5.8.3; \
		curl -fsSL https://raw.githubusercontent.com/k3d-io/k3d/v5.8.3/install.sh | TAG="$$TAG" bash; \
	fi
	@echo "── all dependencies installed ──"
