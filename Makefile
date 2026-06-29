#!make
APP_HOST ?= 0.0.0.0
APP_PORT ?= 8080
EXTERNAL_APP_PORT ?= ${APP_PORT}
LOG_LEVEL ?= warning

run = docker compose run --rm \
				-p ${EXTERNAL_APP_PORT}:${APP_PORT} \
				-e APP_HOST=${APP_HOST} \
				-e APP_PORT=${APP_PORT} \
				app

runtests = docker compose -f compose.yml -f compose.tests.yml run --rm tests

.PHONY: help
help: ## Show this help message
	@awk 'BEGIN {FS = ":.*##"; printf "Usage: make \033[36m<target>\033[0m\n"} \
	     /^### / { printf "\n\033[1;33m%s\033[0m\n", substr($$0, 5) } \
	     /^[a-zA-Z0-9_.-]+:.*?##/ { printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2 }' \
	     $(MAKEFILE_LIST)

### Docker
.PHONY: image
image: ## Build docker image
	docker compose build

.PHONY: image-tests
image-tests: ## Build image for tests
	docker compose -f compose.yml -f compose.tests.yml build

.PHONY: docker-run
docker-run: image ## Run the docker image
	docker compose up

.PHONY: docker-run-nginx-proxy 
docker-run-nginx-proxy: image ## Run the image with nginx proxy
	docker compose -f compose.yml -f compose.nginx.yml up

.PHONY: docker-down-nginx
docker-down-nginx: ## Take down nginx proxy docker compose setup
	docker compose -f compose.yml -f compose.nginx.yml down

.PHONY: docker-down-tests
docker-down-tests: ## Take down the test image container setup
	docker compose -f compose.yml -f compose.tests.yml down

.PHONY: docker-down-all
docker-down-all: ## Take all container setups down
	docker compose down
	docker compose -f compose.yml -f compose.nginx.yml down
	docker compose -f compose.yml -f compose.tests.yml down

### Tests
.PHONY: test
test: ## Run tests in dedicated container
	$(runtests) /bin/bash -c 'export && python -m pytest /app/tests/ --log-cli-level $(LOG_LEVEL)'

.PHONY: pytest
pytest: install ## Run pytest (on host)
	uv run pytest

.PHONY: test-catalogs
test-catalogs: ## Run Catalog Tests
	$(runtests) python -m pytest /app/tests/extensions/test_catalogs.py -v --log-cli-level $(LOG_LEVEL)

### Database
.PHONY: run-database
run-database: ## Run database service
	docker compose run --rm database

.PHONY: load-joplin
load-joplin: ## Run joplin
	python scripts/ingest_joplin.py http://localhost:8082

### Development
.PHONY: install
install: ## Install/sync the dependencies
	uv sync --dev

### Docs
.PHONY: docs
docs: ## Build docs
	uv run --group docs mkdocs build -f docs/mkdocs.yml

### Deploy
GCP_PROJECT_ID ?= resilens-backend
GCP_REGION ?= europe-west6

REGISTRY := europe-west6-docker.pkg.dev/resilens-backend/resilens-app

IMAGE ?= $(REGISTRY)/stac-fastapi-pgstac
IMAGE_TAG ?= resilens
VERSION ?= $(shell cat VERSION)

.PHONY: print-env
print-env: ## Print resolved deploy variables
	@echo "GCP_PROJECT_ID = $(GCP_PROJECT_ID)"
	@echo "GCP_REGION     = $(GCP_REGION)"
	@echo "REGISTRY       = $(REGISTRY)"
	@echo "IMAGE          = $(IMAGE):$(VERSION)-$(IMAGE_TAG)"
	@echo "VERSION        = $(VERSION)"

.PHONY: build
build: ## Build production docker image
	docker buildx build --load \
		--platform=linux/amd64 \
		-t $(IMAGE):$(VERSION)-$(IMAGE_TAG) \
		.

.PHONY: push
push: ## Push production image to Artifacts Registry
	docker push $(IMAGE):$(VERSION)-$(IMAGE_TAG)

.PHONY: prune
prune: ## Clean up docker images
	docker image rm $(IMAGE):$(VERSION)-$(IMAGE_TAG) || true
