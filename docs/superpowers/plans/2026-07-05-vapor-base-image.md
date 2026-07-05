# Vapor Base Image – Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ein einmalig in CI gebautes, gepinntes Laravel-Vapor-Basis-Image (PHP 8.2–8.5 × amd64/arm64) bereitstellen, das alle nötigen PHP-Extensions vorkompiliert enthält, damit `vapor deploy` nicht mehr bei jedem Deploy kompiliert.

**Architecture:** Neues Repo `john-wink/vapor-base` mit einer parametrisierten `Dockerfile` (`FROM laravelphp/vapor:<tag>` + Extensions) und einem GitHub-Actions-Matrix-Build, der 8 Images nach GHCR (+ optional Docker Hub) pusht. Projekte konsumieren das Image per `FROM` und schrumpfen auf ~3 Zeilen. Erster echter Test: Pilot-Deploy von craftplan staging.

**Tech Stack:** Docker (Alpine/musl-Basis von `laravelphp/vapor`), `docker-php-ext-*`-Helper, `pecl`, GitHub Actions (native `ubuntu-24.04-arm`-Runner), GHCR, Laravel Vapor CLI.

## Global Constraints

- PHP-Versionen: **8.2, 8.3, 8.4, 8.5** — einheitliches Extension-Set über alle.
- Image-Tags exakt in Vapor-Konvention: `php82`, `php82-arm`, …, `php85`, `php85-arm` (Punkt entfernt, `-arm` für arm64).
- Registry: **GHCR** `ghcr.io/john-wink/vapor-base` immer; **Docker Hub** zusätzlich nur wenn `DOCKER_USERNAME`/`DOCKER_KEY` gesetzt (resilient).
- arm64 wird auf **nativen** `ubuntu-24.04-arm`-Runnern gebaut (kein QEMU — wir kompilieren C-Extensions).
- Gepinnte Versionen: **imagick 3.8.1** (pecl), **excimer 1.2.6** (pecl, best-effort), **brotli 0.20.0** (Git-Tag `kjdev/php-ext-brotli`).
- Pflicht-Extensions (Build-Assertion): `intl, zip, bcmath, gd, imagick, exif, gmp, brotli, pdo_mysql, fileinfo`.
- Kein Chromium (Browsershot via Sidecar), kein `phpredis` (überall `predis`).
- GitHub-Actions verwenden node24-Majors: `actions/checkout@v5`, `docker/setup-buildx-action@v4`, `docker/login-action@v4`, `docker/build-push-action@v7`.
- Base-Image-Layer entfernen Build-Deps wieder (schlankes Image).

## File Structure

Repo `john-wink/vapor-base` (lokal `/Users/johnwink/VSCode/vapor-base`):
- `Dockerfile` — parametrisiertes Basis-Image (eine Datei für alle 8 Kombinationen)
- `conf.d/00-vapor-base.ini` — sichere php.ini-Defaults (Projekte überschreiben via `overrides.ini`)
- `.github/workflows/build.yml` — Matrix-Build + Push
- `README.md`, `.gitignore`, `LICENSE`

Pilot (fremdes Repo): `/Users/johnwink/Herd/craftplan/staging.Dockerfile` — auf Basis-Image umstellen.

---

### Task 1: Repo-Gerüst + GitHub-Repo anlegen

**Files:**
- Create: `/Users/johnwink/VSCode/vapor-base/README.md`
- Create: `/Users/johnwink/VSCode/vapor-base/.gitignore`
- Create: `/Users/johnwink/VSCode/vapor-base/conf.d/00-vapor-base.ini`

**Interfaces:**
- Produces: das lokale Git-Repo (bereits `git init`, Branch `main`, Spec committet) + ein **öffentliches** GitHub-Repo `john-wink/vapor-base` mit `origin`-Remote.

- [ ] **Step 1: php.ini-Defaults schreiben** — `conf.d/00-vapor-base.ini`:

```ini
; vapor-base Standardwerte – Projekte überschreiben diese via overrides.ini
; (00- lädt vor overrides.ini, daher gewinnen Projekt-Werte)
opcache.enable=1
opcache.validate_timestamps=0
opcache.memory_consumption=256
opcache.max_accelerated_files=20000
realpath_cache_size=4096K
realpath_cache_ttl=600
```

- [ ] **Step 2: README schreiben** — `README.md`:

```markdown
# Laravel Vapor Base Image

Vorgebautes Laravel-Vapor-Basis-Image mit vorkompilierten PHP-Extensions,
damit `vapor deploy` nicht bei jedem Deploy kompiliert.

## Verfügbare Tags
`ghcr.io/john-wink/vapor-base:phpXX` und `:phpXX-arm` für PHP 8.2–8.5.

Enthält: gd, exif, imagick, gmp, brotli, excimer (+ intl/zip/bcmath aus der Vapor-Basis),
sowie ffmpeg und mysql-client.

## Nutzung im Projekt-Dockerfile
```dockerfile
FROM ghcr.io/john-wink/vapor-base:php85          # arm: :php85-arm
COPY ./php/conf.d/php.ini /usr/local/etc/php/conf.d/overrides.ini
COPY . /var/task
```

Gebaut via GitHub Actions (Matrix PHP × Arch). Siehe `.github/workflows/build.yml`.
```

- [ ] **Step 3: .gitignore schreiben** — `.gitignore`:

```
.DS_Store
```

- [ ] **Step 4: GitHub-Repo anlegen und pushen**

Run:
```bash
cd /Users/johnwink/VSCode/vapor-base
git add -A && git commit -q -m "Repo-Gerüst: README, php.ini-Defaults, .gitignore"
gh repo create john-wink/vapor-base --public --source=. --remote=origin --push
```
Expected: `gh` legt das Repo an und pusht `main`.

- [ ] **Step 5: Verifizieren**

Run: `gh repo view john-wink/vapor-base --json name,visibility,isEmpty --jq '.name, .visibility, .isEmpty'`
Expected: `vapor-base`, `PUBLIC`, `false`.

---

### Task 2: Parametrisierte Basis-Dockerfile

**Files:**
- Create: `/Users/johnwink/VSCode/vapor-base/Dockerfile`

**Interfaces:**
- Consumes: `ARG VAPOR_TAG` (z. B. `php85` / `php85-arm`), `ARG PHP_VERSION` (Label), gepinnte Versionen als `ARG`.
- Produces: ein Image mit allen Pflicht-Extensions; eine `RUN`-Assertion bricht den Build ab, falls eine Pflicht-Extension fehlt.

> **Hinweis:** Lokal ist kein Docker verfügbar → die Validierung dieser Datei erfolgt in **Task 4** über den CI-Build. Diese Task endet daher mit Commit; der Test ist der erste grüne Build.

- [ ] **Step 1: Dockerfile schreiben**

```dockerfile
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
```

- [ ] **Step 2: Commit**

```bash
cd /Users/johnwink/VSCode/vapor-base
git add Dockerfile && git commit -q -m "Parametrisierte Vapor-Basis-Dockerfile mit gepinnten Extensions"
```

---

### Task 3: GitHub-Actions-Matrix-Workflow

**Files:**
- Create: `/Users/johnwink/VSCode/vapor-base/.github/workflows/build.yml`

**Interfaces:**
- Consumes: `Dockerfile` (`VAPOR_TAG`, `PHP_VERSION` build-args), Secrets `DOCKER_USERNAME`/`DOCKER_KEY` (optional), `GITHUB_TOKEN`.
- Produces: gepushte Tags `phpXX[-arm]` in GHCR (+ Docker Hub). `workflow_dispatch`-Input `php` erlaubt Bau einer einzelnen Version.

- [ ] **Step 1: Workflow schreiben**

```yaml
name: Build & Push Vapor base images

on:
  push:
    branches: [main]
    paths: ['Dockerfile', 'conf.d/**', '.github/workflows/build.yml']
  workflow_dispatch:
    inputs:
      php:
        description: 'Nur diese PHP-Version bauen (leer = alle)'
        required: false
        default: ''
  schedule:
    - cron: '0 5 * * 1'   # montags 05:00 UTC – Updates der Vapor-Basis

env:
  IMAGE: vapor-base

jobs:
  build:
    permissions:
      contents: read
      packages: write
    strategy:
      fail-fast: false
      matrix:
        php: ['8.2', '8.3', '8.4', '8.5']
        arch:
          - { name: amd64, runner: ubuntu-latest,    suffix: '' }
          - { name: arm64, runner: ubuntu-24.04-arm, suffix: '-arm' }
    runs-on: ${{ matrix.arch.runner }}
    env:
      HAS_DOCKERHUB: ${{ secrets.DOCKER_USERNAME != '' && secrets.DOCKER_KEY != '' }}
    steps:
      - name: Gate (workflow_dispatch php-Filter)
        id: gate
        env:
          WANT: ${{ github.event.inputs.php }}
          HAVE: ${{ matrix.php }}
        run: |
          if [ -n "$WANT" ] && [ "$WANT" != "$HAVE" ]; then
            echo "skip=true" >> "$GITHUB_OUTPUT"
          else
            echo "skip=false" >> "$GITHUB_OUTPUT"
          fi

      - name: Checkout
        if: steps.gate.outputs.skip == 'false'
        uses: actions/checkout@v5

      - name: Set up Buildx
        if: steps.gate.outputs.skip == 'false'
        uses: docker/setup-buildx-action@v4

      - name: Login to GHCR
        if: steps.gate.outputs.skip == 'false'
        uses: docker/login-action@v4
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Login to Docker Hub
        if: steps.gate.outputs.skip == 'false' && env.HAS_DOCKERHUB == 'true'
        uses: docker/login-action@v4
        with:
          username: ${{ secrets.DOCKER_USERNAME }}
          password: ${{ secrets.DOCKER_KEY }}

      - name: Compute tags
        if: steps.gate.outputs.skip == 'false'
        id: meta
        env:
          DOCKER_USER: ${{ secrets.DOCKER_USERNAME }}
          PHP: ${{ matrix.php }}
          SUFFIX: ${{ matrix.arch.suffix }}
        run: |
          PHP_NODOT="${PHP//./}"
          VAPOR_TAG="php${PHP_NODOT}${SUFFIX}"
          GHCR="ghcr.io/${{ github.repository_owner }}/${IMAGE}"
          TAGS="${GHCR}:${VAPOR_TAG}"
          if [ "${HAS_DOCKERHUB}" = "true" ]; then
            TAGS="${TAGS},${DOCKER_USER}/${IMAGE}:${VAPOR_TAG}"
          fi
          echo "vapor_tag=${VAPOR_TAG}" >> "$GITHUB_OUTPUT"
          echo "tags=${TAGS}" >> "$GITHUB_OUTPUT"
          echo "VAPOR_TAG=${VAPOR_TAG}  TAGS=${TAGS}"

      - name: Build & push
        if: steps.gate.outputs.skip == 'false'
        uses: docker/build-push-action@v7
        with:
          context: .
          platforms: linux/${{ matrix.arch.name }}
          push: true
          build-args: |
            VAPOR_TAG=${{ steps.meta.outputs.vapor_tag }}
            PHP_VERSION=${{ matrix.php }}
          tags: ${{ steps.meta.outputs.tags }}
          cache-from: type=gha,scope=${{ steps.meta.outputs.vapor_tag }}
          cache-to: type=gha,mode=max,scope=${{ steps.meta.outputs.vapor_tag }}
```

- [ ] **Step 2: Commit + Push**

```bash
cd /Users/johnwink/VSCode/vapor-base
git add .github/workflows/build.yml
git commit -q -m "GitHub-Actions-Matrix: PHP 8.2-8.5 x amd64/arm64 -> GHCR/Docker Hub"
git push
```

- [ ] **Step 3: Workflow-Registrierung verifizieren**

Run: `gh workflow list -R john-wink/vapor-base`
Expected: „Build & Push Vapor base images  active".

---

### Task 4: Erster Build (PHP 8.5, beide Arch) + offene Punkte lösen

**Interfaces:**
- Consumes: Workflow aus Task 3.
- Produces: verifizierte `php85` + `php85-arm` Images in GHCR; endgültige Bestätigung der Pins & des Extension-Sets.

> **Manueller Vorabschritt (User), falls Docker-Hub-Push gewünscht:** `gh secret set DOCKER_USERNAME -R john-wink/vapor-base` und `gh secret set DOCKER_KEY -R john-wink/vapor-base`. Ohne die Secrets läuft nur der GHCR-Push (resilient).

- [ ] **Step 1: Nur PHP 8.5 bauen (beide Arch)**

Run:
```bash
gh workflow run build.yml -R john-wink/vapor-base -f php=8.5
sleep 6
gh run list -R john-wink/vapor-base --limit 1
```
Expected: ein Run wird gestartet (Status `queued`/`in_progress`).

- [ ] **Step 2: Run beobachten**

Run: `gh run watch <RUN_ID> -R john-wink/vapor-base --exit-status --interval 20`
Expected: Beide Jobs (`build (8.5, amd64)`, `build (8.5, arm64)`) grün.

- [ ] **Step 3: Bei Assertion-Fehler „FEHLENDE EXTENSIONS" reagieren**

Falls der Build mit `FEHLENDE EXTENSIONS: <ext…>` abbricht: fehlende Extension(s) in Task-2-`Dockerfile` ergänzen (bei `intl`/`zip`/`bcmath`: `docker-php-ext-install <ext>` in den Build-RUN aufnehmen; nötige `-dev`-Pakete zu `.build-deps` hinzufügen), committen, `git push`, dann Step 1 wiederholen. Bei imagick-Fehler auf 8.5: aktuelle 8.5-kompatible Version auf `https://pecl.php.net/package/imagick` prüfen und `IMAGICK_VERSION` anpassen.

- [ ] **Step 4: Images anonym prüfen (GHCR public)**

Run:
```bash
tok=$(curl -s "https://ghcr.io/token?scope=repository:john-wink/vapor-base:pull" | sed -E 's/.*"token":"([^"]+)".*/\1/')
curl -s -H "Authorization: Bearer $tok" "https://ghcr.io/v2/john-wink/vapor-base/tags/list" | tr ',' '\n' | grep -oE '"php85[^"]*"'
```
Expected: `"php85"` und `"php85-arm"` erscheinen.

---

### Task 5: Volle Matrix bauen (alle 8 Images)

**Interfaces:**
- Produces: alle 8 Tags (`php82`…`php85`, jeweils `-arm`) in GHCR (+ Docker Hub).

- [ ] **Step 1: Alle Versionen bauen**

Run:
```bash
gh workflow run build.yml -R john-wink/vapor-base   # ohne -f php → alle
sleep 6 && gh run list -R john-wink/vapor-base --limit 1
```
Expected: Run mit 8 Jobs startet.

- [ ] **Step 2: Auf Abschluss warten**

Run: `gh run watch <RUN_ID> -R john-wink/vapor-base --exit-status --interval 30`
Expected: alle 8 Jobs grün. (Bei einzelnem excimer-WARN: kein Fehler, best-effort.)

- [ ] **Step 3: Alle 8 Tags verifizieren**

Run:
```bash
tok=$(curl -s "https://ghcr.io/token?scope=repository:john-wink/vapor-base:pull" | sed -E 's/.*"token":"([^"]+)".*/\1/')
curl -s -H "Authorization: Bearer $tok" "https://ghcr.io/v2/john-wink/vapor-base/tags/list" | tr ',' '\n' | grep -oE '"php8[2-5](-arm)?"' | sort -u
```
Expected: 8 Zeilen — `php82`, `php82-arm`, `php83`, `php83-arm`, `php84`, `php84-arm`, `php85`, `php85-arm`.

---

### Task 6: Pilot – craftplan staging auf Basis-Image umstellen & deployen

**Files:**
- Modify: `/Users/johnwink/Herd/craftplan/staging.Dockerfile` (komplett ersetzen)

**Interfaces:**
- Consumes: `ghcr.io/john-wink/vapor-base:php85` (aus Task 5).

> Validiert die tragende Annahme, dass Vapor ein abgeleitetes (chained) `FROM`-Basis-Image akzeptiert. craftplan staging ist `runtime: docker` (amd64) → Tag `php85`. Der Wechsel von `php84`→`php85`-Basis behebt zugleich den composer-`^8.5`-Mismatch.

- [ ] **Step 1: staging.Dockerfile ersetzen**

Inhalt von `/Users/johnwink/Herd/craftplan/staging.Dockerfile`:
```dockerfile
FROM ghcr.io/john-wink/vapor-base:php85
COPY ./php/conf.d/php.ini /usr/local/etc/php/conf.d/overrides.ini
COPY . /var/task
```

- [ ] **Step 2: Deployen**

Run: `cd /Users/johnwink/Herd/craftplan && vapor deploy staging`
Expected: Deploy läuft durch; der Image-Build-Teil zeigt **keine** Extension-Kompilierung mehr (nur Pull des Basis-Images + `COPY`), und ist spürbar schneller.

- [ ] **Step 3: Verifizieren**

Prüfen: staging-Domain lädt (`https://staging.craftplan.net`), und eine Funktion, die imagick/gd/PDF nutzt (z. B. Medialibrary-Upload oder PDF-Erzeugung), funktioniert. Bei Bedarf `vapor` Logs prüfen: `vapor logs staging`.
Expected: App gesund, keine „missing extension"-Fehler.

- [ ] **Step 4: Commit (craftplan-Repo)**

```bash
cd /Users/johnwink/Herd/craftplan
git add staging.Dockerfile
git commit -m "Vapor staging auf gemeinsames vapor-base:php85 umstellen"
```

---

### Task 7 (Rollout, nach erfolgreichem Pilot): restliche Dockerfiles migrieren

Pro Datei nach demselben Muster ersetzen (arm-Umgebungen → `:php85-arm`), einzeln deployen und verifizieren. Reihenfolge risikoaufsteigend:

1. `craftplan/production.Dockerfile` → `FROM ghcr.io/john-wink/vapor-base:php85`
2. `app-ys-consulting/staging.Dockerfile` → `:php85` (danach production; **Octane** dabei explizit auf staging verifizieren)
3. `app-ys-consulting/production.Dockerfile` → `:php85`
4. `finance-estate/estateoftheart.Dockerfile` → `:php85` (x86-Umgebungen)
5. `finance-estate/estateoftheart-arm.Dockerfile` → `:php85-arm` (docker-arm-Umgebungen)

Jede Umgebung: Dockerfile ersetzen → `vapor deploy <env>` → verifizieren → committen. Kein `--ignore-platform-req` mehr nötig, sobald die Basis zur composer-Version passt.

## Self-Review

**Spec-Abdeckung:** PHP 8.2–8.5 × arm/amd64 (Tasks 3/5) ✓ · vorkompilierte Extensions + Pin (Task 2) ✓ · `php -m`-Assertion (Task 2) ✓ · GHCR + resilientes Docker Hub (Task 3) ✓ · native arm-Runner (Task 3) ✓ · imagick-Pin ersetzt Branch-Build, Befund #1 (Task 2) ✓ · Pilot craftplan staging inkl. 8.4→8.5-Fix, Befund #2/#3 (Task 6) ✓ · native arm-Bereitstellung ohne Prod-Zwang (Task 7) ✓.
**Platzhalter:** keine offenen TBD/TODO; die drei Spec-Offenpunkte sind in Task 2 (imagick/excimer gepinnt) bzw. Task 4 (empirische Bestätigung) konkret aufgelöst.
**Typ-/Namenskonsistenz:** `VAPOR_TAG`, Tag-Schema `phpXX[-arm]`, Extension-Set und Image-Name `vapor-base` durchgängig identisch in Tasks 2/3/4/5/6.
