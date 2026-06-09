# freshrss-digest — Docker 이미지 빌드 & Docker Hub 푸시
#
# 사용 예:
#   make build                # 로컬 아키텍처로 빌드
#   make login                # Docker Hub 로그인 (1회)
#   make push                 # :latest 와 :<TAG> 푸시 (single-arch)
#   make release              # buildx 로 멀티아키(amd64+arm64) 빌드 후 바로 푸시 ← 권장
#   make TAG=v1.0.0 release    # 버전 태그 지정
#
# 서버(amd64)에서 돌리는데 맥(arm64)에서 푸시한다면 `make release` 를 쓰세요.

IMAGE ?= kobums/freshrss-digest
TAG   ?= latest
PLATFORMS ?= linux/amd64,linux/arm64

.DEFAULT_GOAL := help

.PHONY: help
help: ## 사용 가능한 타깃 목록
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

.PHONY: login
login: ## Docker Hub 로그인 (docker login)
	docker login

.PHONY: build
build: ## 로컬 아키텍처로 이미지 빌드 (IMAGE:TAG, IMAGE:latest)
	docker build -t $(IMAGE):$(TAG) -t $(IMAGE):latest .

.PHONY: push
push: build ## 빌드 후 :TAG 와 :latest 를 Docker Hub 에 푸시 (single-arch)
	docker push $(IMAGE):$(TAG)
	docker push $(IMAGE):latest

.PHONY: release
release: ## buildx 로 멀티아키(amd64+arm64) 빌드 후 곧바로 푸시 ← 권장
	docker buildx build \
	  --platform $(PLATFORMS) \
	  -t $(IMAGE):$(TAG) -t $(IMAGE):latest \
	  --push .

.PHONY: buildx-init
buildx-init: ## (1회) 멀티아키 빌드용 buildx 빌더 생성·활성화
	docker buildx create --name digestbuilder --use --bootstrap || docker buildx use digestbuilder

.PHONY: run
run: ## 로컬에서 한 번 실행 (.env 의 토큰으로 인증 + 데이터 볼륨)
	docker run --rm \
	  --env-file .env \
	  -v $(PWD)/digest-data:/data \
	  $(IMAGE):$(TAG)
