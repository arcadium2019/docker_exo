# syntax=docker/dockerfile:1.7
# GestStock - PHP 8.3 + Apache (single process), non-root, logs to stdout/stderr.
ARG PHP_IMAGE=php:8.3.35-apache-trixie

# ---- ext: compiles pdo_mysql (only the .so and its ini are copied to the runtime)
FROM ${PHP_IMAGE} AS ext
RUN docker-php-ext-install -j"$(nproc)" pdo_mysql

# ---- supercronic: cron runner made for containers (no root, logs on stdout), checksum pinned
FROM alpine:3.20 AS supercronic
SHELL ["/bin/ash", "-eo", "pipefail", "-c"]
ARG SUPERCRONIC_VERSION=v0.2.51
ARG SUPERCRONIC_SHA256=cc232108374e8e2b537045f2d5eaa1229f619db314c3ba6a14d38b35dc0aa123
RUN wget -qO /supercronic "https://github.com/aptible/supercronic/releases/download/${SUPERCRONIC_VERSION}/supercronic-linux-amd64" \
    && echo "${SUPERCRONIC_SHA256}  /supercronic" | sha256sum -c - \
    && chmod 0755 /supercronic

# ---- test: syntax check of every PHP file with PHP 8.3
FROM ${PHP_IMAGE} AS test
SHELL ["/bin/bash", "-eo", "pipefail", "-c"]
COPY app /src
RUN find /src -name '*.php' -print0 | xargs -0 -n1 php -l

# ---- runtime
FROM ${PHP_IMAGE} AS runtime
ARG PHP_IMAGE
ARG VERSION=0.0.0-dev
ARG GIT_SHA=unknown
ARG SOURCE_URL=https://git.shop-sas.example/platform/geststock-docker
LABEL org.opencontainers.image.title="geststock" \
      org.opencontainers.image.description="GestStock inventory (legacy PHP app, containerized)" \
      org.opencontainers.image.vendor="Shop SAS" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${GIT_SHA}" \
      org.opencontainers.image.source="${SOURCE_URL}" \
      org.opencontainers.image.base.name="${PHP_IMAGE}"

# msmtp replaces the legacy postfix relay for mail(); security updates of the base image.
RUN apt-get update \
    && apt-get upgrade -y \
    && apt-get install -y --no-install-recommends msmtp \
    && rm -rf /var/lib/apt/lists/*

COPY --from=ext /usr/local/lib/php/extensions/ /usr/local/lib/php/extensions/
COPY --from=ext /usr/local/etc/php/conf.d/docker-php-ext-pdo_mysql.ini /usr/local/etc/php/conf.d/
COPY --from=supercronic /supercronic /usr/local/bin/supercronic

RUN cp /usr/local/etc/php/php.ini-production /usr/local/etc/php/php.ini \
    && a2dissite 000-default >/dev/null \
    && : > /etc/apache2/ports.conf
COPY docker/php/zz-geststock.ini /usr/local/etc/php/conf.d/
COPY docker/apache/geststock.conf /etc/apache2/sites-available/
COPY docker/cron/crontab /etc/geststock/crontab
RUN a2ensite geststock >/dev/null \
    && mkdir -p /var/www/html/uploads && chown www-data:www-data /var/www/html/uploads

# Code owned by root: www-data can read it, not modify it.
COPY app /var/www/geststock

ENV APP_VERSION=${VERSION} \
    SMTP_HOST=localhost \
    SMTP_PORT=25 \
    MAIL_FROM=geststock@shop.example
# Numeric uid:gid (= www-data) so runAsNonRoot-style checks work without /etc/passwd.
USER 33:33
EXPOSE 8080
HEALTHCHECK --interval=15s --timeout=3s --start-period=10s --start-interval=1s --retries=3 \
    CMD ["curl", "-fsS", "-o", "/dev/null", "http://127.0.0.1:8080/?health"]
CMD ["apache2-foreground"]
