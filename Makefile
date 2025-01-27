SHELL=/bin/bash -euxo pipefail
BIN=$(shell go env GOPATH)/bin

## Build tools.
GO_BINDATA=$(BIN)/go-bindata
GENNY=$(BIN)/genny
GOLANGCI_LINT=$(BIN)/golangci-lint

## Test tools.
GO_JUNIT_REPORT=$(BIN)/go-junit-report

## Release tools.
GORELEASER=$(BIN)/goreleaser
GODOWNLOADER=$(BIN)/godownloader

## Configurations.
IMAGE?=buildtools
GORELEASER_FLAGS?=--rm-dist
GCFLAGS:=-gcflags 'all=-trimpath=${GOPATH}'
LDFLAGS:=-ldflags '-extldflags "-static" -X github.com/fossas/fossa-cli/cmd/fossa/version.version=$(shell git rev-parse --abbrev-ref HEAD) -X github.com/fossas/fossa-cli/cmd/fossa/version.commit=$(shell git rev-parse HEAD) -X "github.com/fossas/fossa-cli/cmd/fossa/version.goversion=$(shell go version)" -X github.com/fossas/fossa-cli/cmd/fossa/version.buildType=development'

all: build

# Installing tools.
$(GO_BINDATA):
	go get -u -v github.com/go-bindata/go-bindata/...

$(GENNY):
	go get -u -v github.com/cheekybits/genny

$(GOLANGCI_LINT):
	go get -u github.com/golangci/golangci-lint/cmd/golangci-lint

$(GO_JUNIT_REPORT):
	go get -u -v github.com/jstemmer/go-junit-report

$(GORELEASER):
	go get -d github.com/goreleaser/goreleaser
	cd $$GOPATH/src/github.com/goreleaser/goreleaser
	go install github.com/goreleaser/goreleaser

$(GODOWNLOADER):
	mkdir -p $$GOPATH/src/github.com/goreleaser
	cd $$GOPATH/src/github.com/goreleaser && git clone https://github.com/goreleaser/godownloader
	go install github.com/goreleaser/godownloader

# Building the CLI.
.PHONY: build
build: $(BIN)/fossa

$(BIN)/fossa: $(GO_BINDATA) $(GENNY) $(shell find . -name *.go)
	go mod download
	go mod tidy
	go generate ./...
	go build -o $@ $(GCFLAGS) $(LDFLAGS) github.com/fossas/fossa-cli/cmd/fossa

# Building various Docker images.
.PHONY:
docker-base: ./docker/base/Dockerfile
	sudo docker build -t fossa/fossa-cli:base -f ./docker/base/Dockerfile $(DOCKER_FLAGS) .

.PHONY:
docker-buildtools: docker-base ./docker/buildtools/Dockerfile
	sudo docker build -t fossa/fossa-cli:buildtools -f ./docker/buildtools/Dockerfile $(DOCKER_FLAGS) .

## TODO: we will deprecate this image once native integration tests are
## completely ready.
.PHONY:
docker-fixtures: docker-buildtools ./docker/fixtures/Dockerfile
	sudo docker build -t fossa/fossa-cli:fixtures -f ./docker/fixtures/Dockerfile $(DOCKER_FLAGS) .

# Development tasks.
.PHONY: dev
dev: docker-$(IMAGE)
	sudo docker run --rm -it \
		-v $$GOPATH/src/github.com/fossas/fossa-cli:/home/fossa/go/src/github.com/fossas/fossa-cli \
		-v $$GOPATH/bin:/home/fossa/go/bin \
		fossa/fossa-cli:$(IMAGE) /bin/bash

# We don't mount the $GOPATH/bin because the host machine's binaries are
# compiled for Darwin and won't run on Docker (Linux).
.PHONY: dev-osx
dev-osx: docker-$(IMAGE)
	docker run --rm -it \
		-v $$GOPATH/src/github.com/fossas/fossa-cli:/home/fossa/go/src/github.com/fossas/fossa-cli \
		fossa/fossa-cli:$(IMAGE) /bin/bash

.PHONY: lint
lint: $(GOLANGCI_LINT)
	golangci-lint run

.PHONY: clean
clean:
	rm -f $(BIN)/fossa
	find . -name *_generated.go | grep -v vendor | xargs rm -f

# Testing tasks.
.PHONY: test
test:
	make unit-test
	make integration-test

.PHONY: unit-test
unit-test:
	go test -short -covermode=atomic $(GO_TEST_FLAGS) ./...

.PHONY: ci-unit-test
ci-unit-test: $(GO_JUNIT_REPORT)
	GO_TEST_FLAGS="-coverprofile=coverage.txt -v" make -s unit-test | go-junit-report
	if [ -n "$${CODECOV_TOKEN}" ]; then curl -s https://codecov.io/bash | bash 1>&2; fi

.PHONY: integration-test
integration-test:
	# Ensure the binary is recompiled before every test.
	make
	go test -covermode=atomic $(GO_TEST_FLAGS) ./...

.PHONY: ci-integration-test
ci-integration-test: $(GO_JUNIT_REPORT)
	GO_TEST_FLAGS="-coverprofile=coverage.txt -v" make -s integration-test | go-junit-report
	if [ -n "$${CODECOV_TOKEN}" ]; then curl -s https://codecov.io/bash | bash 1>&2; fi

# Release tasks.
install.sh: $(GODOWNLOADER)
	# 1. Set default installation location to /usr/local/bin.
	# 2. Create /usr/local/bin. First try with and 775 permissions and fall back to default.
	# 3. Try `sudo install` when `install` fails.
	godownloader --repo=fossas/fossa-cli \
		| sed 's/\.\/bin/\/usr\/local\/bin/' \
		| sed 's/install -d "$${BINDIR}"/install -d -m 775 "$${BINDIR}" 2> \/dev\/null || install -d "$${BINDIR}"/' \
		| sed 's/install "$${srcdir}\/$${binexe}" "$${BINDIR}\/"/install "$${srcdir}\/$${binexe}" "$${BINDIR}\/" 2> \/dev\/null || sudo install "$${srcdir}\/$${binexe}" "$${BINDIR}\/"/' \
		> install.sh

.PHONY: release
release: $(GORELEASER) install.sh
	# Check that the commit is tagged and starts with "v".
	[[ $$(git tag -l --points-at HEAD) == v* ]]
	GOVERSION=$$(go version) goreleaser $(GORELEASER_FLAGS)
