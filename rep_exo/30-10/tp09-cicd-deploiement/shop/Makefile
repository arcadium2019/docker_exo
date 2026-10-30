PROD = docker compose -f compose.yml -f compose.prod.yml

.PHONY: up down prod-up prod-down migrate tools test config

up:
	docker compose up -d --wait

down:
	docker compose --profile tools down

prod-up:
	$(PROD) up -d --wait

prod-down:
	$(PROD) down

migrate:
	MIGRATION=$(M) docker compose run --rm migrate

tools:
	docker compose --profile tools up -d --wait

test:
	./smoke-test.sh

config:
	docker compose config
