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
# imagemagick-heic: Alpine liefert die ImageMagick-Delegaten als eigene Pakete
# aus. Ohne dieses Paket kennt ImageMagick das Format zwar dem Namen nach
# (Imagick::queryFormats('HEI*') listet es), kann es aber weder lesen noch
# schreiben — jeder Lesevorgang scheitert mit "no decode delegate". iPhones
# fotografieren standardmäßig in HEIC, also trifft das den häufigsten Upload.
# Im selben apk-Aufruf wie imagemagick, damit die Versionen zusammenpassen;
# libheif zieht apk als Abhängigkeit mit.
RUN apk add --no-cache --update \
      ffmpeg \
      mysql-client \
      imagemagick \
      imagemagick-heic \
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

# --- Assertion: HEIC-Delegat muss vorhanden sein ---
# `Imagick::queryFormats('HEI*')` genügt als Prüfung NICHT — es listet HEIC
# auch dann, wenn der Delegat fehlt. Genau daran ist es hier unbemerkt
# gescheitert: der Name war da, das Dekodieren nicht.
# Geprüft wird deshalb, dass das Paket wirklich installiert ist. Ein Round-Trip
# über Imagick wäre verlockend, taugt aber nicht: HEIC zu SCHREIBEN braucht
# zusätzlich einen HEVC-Encoder, den Alpine nicht zwingend mitliefert — ein
# Schreibtest würde den Build grundlos brechen, obwohl Lesen genügt (die
# Anwendung dekodiert Uploads und schreibt JPEG).
# Die Delegat-Liste wird zusätzlich ins Build-Log geschrieben, ohne den Build
# davon abhängig zu machen; ihr Format ist zwischen ImageMagick-Versionen
# nicht stabil genug für eine harte Bedingung.
RUN set -eux; \
    apk info -e imagemagick-heic > /dev/null \
      || { echo "FEHLER: Paket imagemagick-heic ist nicht installiert."; exit 1; }; \
    echo "--- ImageMagick-Delegaten (zur Sichtkontrolle im Build-Log) ---"; \
    { magick -list format 2>/dev/null || identify -list format 2>/dev/null || true; } \
      | grep -iE '^[[:space:]]*(JPEG|PNG|WEBP|HEIC|HEIF)' || true; \
    echo "imagemagick-heic installiert."

# --- Assertion: ffmpeg-Versionslinie + echte HEIC-Dekodier-Fähigkeit ---
# ffmpeg kommt als floatendes `apk add ffmpeg` — Alpine bestimmt die Version.
# Am 17.08.2026 hat genau so ein stiller Versions-Unterschied (CI-Ubuntu apt
# 6.1 ohne HEIF-Demuxer) die Chat-Medien-Pipeline gebrochen. Dieser Block
# macht aus stillem Drift einen lauten Build-Fehler:
#
# 1. Versionslinie gepinnt via FFMPEG_ASSERT_MAJOR (der Workflow setzt sie
#    NUR für die 8.5-Linie, die app-ys production/staging trägt — ältere
#    Vapor-Basen sitzen auf älterem Alpine mit ffmpeg 6.x und geben diese
#    Zusicherung nicht ab; der erste Lauf hat das prompt bewiesen: php82
#    liefert 6.1.2). Bumpt Alpine die Linie, bricht der Build — der Bump wird
#    dann BEWUSST im Workflow gemacht und gegen die CI-Seite geprüft
#    (laravel-ci spiegelt BtbN n8.1 als ffmpeg-mirror-Release).
# 2. Die Probe ist eine ECHTE iPhone-HEIC (item-basiertes HEIF) aus der
#    App-Testsuite (tests/Fixtures/sample-iphone-photo.heic) — exakt der
#    Transkodier-Pfad, den ImageMediaConverter in Produktion fährt
#    (HEIC → JPEG). `ffmpeg -version` allein genügt NICHT: die Fähigkeit
#    hängt an einkompilierten Demuxern/Decodern, nicht an der Versionsnummer.
ARG FFMPEG_ASSERT_MAJOR=""
COPY assets/sample-iphone-photo.heic /tmp/heic-probe.heic
RUN set -eux; \
    ffmpeg -version | head -1; \
    if [ -z "${FFMPEG_ASSERT_MAJOR}" ]; then \
      echo "ffmpeg-Assertion übersprungen (FFMPEG_ASSERT_MAJOR leer — dieses Image gibt keine HEIC-Zusicherung ab)."; \
      rm -f /tmp/heic-probe.heic; \
    else \
      ffmpeg -version | head -1 | grep -Eq "^ffmpeg version ${FFMPEG_ASSERT_MAJOR}\." \
        || { echo "FEHLER: ffmpeg ist nicht mehr Versionslinie ${FFMPEG_ASSERT_MAJOR}.x — bewusst bumpen (Kommentar oben)."; exit 1; }; \
      ffmpeg -hide_banner -y -i /tmp/heic-probe.heic -frames:v 1 /tmp/heic-probe.jpg \
        || { echo "FEHLER: ffmpeg kann iPhone-HEIC nicht nach JPEG dekodieren."; exit 1; }; \
      rm -f /tmp/heic-probe.heic /tmp/heic-probe.jpg; \
      echo "ffmpeg ${FFMPEG_ASSERT_MAJOR}.x mit HEIC-Dekodierung bestätigt."; \
    fi
