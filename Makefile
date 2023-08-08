#!/bin/bash
.PHONY: help build ls

all: build build-b build-d ls

help: ## display help
	@grep -E '^[a-zA-Z0-9_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}'


build17: ## build
	docker build --build-arg JDK_VERSION=17 -t hellospring:jdk17 -f Dockerfile .

build11: ## build
	docker build --build-arg JDK_VERSION=11 -t hellospring:jdk11 -f Dockerfile .

run: ## run
	docker run -p 8080:8080 -t hellospring:latest

rmia: ## remomve all images
	docker rmi -f $(shell docker images -a -q)

ls: ## list images
	docker images

clean: ## clean
	@rm -rf bin
	@rm -rf build