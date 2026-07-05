# Parametrisiertes Laravel-Vapor-Basis-Image.
# VAPOR_TAG wird vom Workflow gesetzt (z. B. php85 oder php85-arm).
ARG VAPOR_TAG=php85
FROM laravelphp/vapor:${VAPOR_TAG}

# Nur für Labels/Metadaten; Tag-String-Manipulation ist in Dockerfiles nicht möglich.
ARG PHP_VERSION=8.5
ARG IMAGICK_VERSION=3.8.1
ARG EXCIMER_VERSION=1.2.6
ARG BROTLI_VERSION=0.20.0

LABEL org.opencontainers.image.source="https://github.com/john-wink/vapor-base"
LABEL php.version="${PHP_VERSION}"

USER root

# --- Runtime-Systempakete (bleiben im Image) ---
RUN apk add --no-cache --update \
      ffmpeg \
      mysql-client \
      imagemagick \
      ghostscript \
      libpng libjpeg-turbo freetype libwebp \
      gmp \
      brotli-libs \
      icu-data-full musl-locales tzdata

# --- Build-Deps + Extensions (Build-Deps werden am Ende entfernt) ---
RUN set -eux; \
    apk add --no-cache --virtual .build-deps \
      ${PHPIZE_DEPS} git \
      imagemagick-dev \
      libpng-dev libjpeg-turbo-dev freetype-dev libwebp-dev \
      gmp-dev brotli-dev icu-dev; \
    docker-php-ext-configure gd --with-freetype --with-jpeg --with-webp; \
    docker-php-ext-install -j"$(nproc)" gd exif gmp; \
    printf '\n' | pecl install "imagick-${IMAGICK_VERSION}"; \
    docker-php-ext-enable imagick; \
    git clone --depth 1 --branch "${BROTLI_VERSION}" --recursive \
      https://github.com/kjdev/php-ext-brotli.git /tmp/brotli; \
    cd /tmp/brotli && phpize && ./configure && make -j"$(nproc)" && make install; \
    docker-php-ext-enable brotli; \
    cd / && rm -rf /tmp/brotli; \
    apk del --no-network .build-deps

# --- excimer: best-effort (nicht jede Arch/Version wird unterstützt, darf nicht hart brechen) ---
RUN set -eux; \
    apk add --no-cache --virtual .excimer-deps ${PHPIZE_DEPS}; \
    if printf '\n' | pecl install "excimer-${EXCIMER_VERSION}" && docker-php-ext-enable excimer; then \
      echo "excimer ${EXCIMER_VERSION} installiert"; \
    else \
      echo "WARN: excimer für ${VAPOR_TAG} nicht installiert (best-effort)"; \
    fi; \
    apk del --no-network .excimer-deps

# --- php.ini-Defaults (Projekte überschreiben via overrides.ini) ---
COPY conf.d/00-vapor-base.ini /usr/local/etc/php/conf.d/00-vapor-base.ini

# --- Assertion: Pflicht-Extensions müssen geladen sein, sonst Build-Abbruch ---
RUN set -eux; \
    MISSING=""; \
    for ext in intl zip bcmath gd imagick exif gmp brotli pdo_mysql fileinfo; do \
      php -m | tr '[:upper:]' '[:lower:]' | grep -qx "$ext" || MISSING="$MISSING $ext"; \
    done; \
    if [ -n "$MISSING" ]; then echo "FEHLENDE EXTENSIONS:$MISSING"; php -m; exit 1; fi; \
    echo "Alle Pflicht-Extensions vorhanden."
