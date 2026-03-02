.PHONY: lint format format-check build serve test

lint:
	./scripts/lint.sh

format:
	./scripts/format.sh

format-check:
	./scripts/format-check.sh

build:
	./scripts/build.sh

serve:
	rojo serve default.project.json

test:
	./scripts/test.sh
