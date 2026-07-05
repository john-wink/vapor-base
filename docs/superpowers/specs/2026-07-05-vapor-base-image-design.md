# Design: Gemeinsames Laravel-Vapor-Basis-Image (`vapor-base`)

- **Datum:** 2026-07-05
- **Status:** Entwurf zur Freigabe
- **Autor:** john-wink (+ Claude)

## 1. Kontext & Problem

Drei Laravel-Projekte deployen via **Laravel Vapor** im Docker-Runtime nach AWS Lambda:

| Projekt | Dockerfiles | Basis heute | Besonderheit |
|---|---|---|---|
| finance-estate (EstateOfTheArt) | `estateoftheart.Dockerfile`, `estateoftheart-arm.Dockerfile` | `laravelphp/vapor:php85` / `php85-arm` | nutzt x86 **und** arm (Graviton) produktiv |
| app-ys-consulting (OnlineCoach) | `production.Dockerfile`, `staging.Dockerfile` | `laravelphp/vapor:php85` | Octane aktiv |
| craftplan | `production.Dockerfile`, `staging.Dockerfile` | `laravelphp/vapor:php84` | composer verlangt `^8.5` (Mismatch) |

**Kernproblem:** Jedes `vapor deploy` kompiliert `imagick`, `brotli`, `gd` (teils `excimer`) **bei jedem Deploy neu aus dem Quellcode** (`git clone` → `phpize` → `configure` → `make`). Das kostet mehrere Minuten reiner C-Kompilierung pro Deploy und pro Umgebung.

**Sekundärprobleme (bei der Analyse gefunden):**
1. **Fragil:** `imagick` wird aus beweglichen Branches gebaut (`develop` bzw. `master`) und uneinheitlich je Arch. Ein schlechter Upstream-Commit kann alle Deploys gleichzeitig brechen.
2. **Mismatch:** `craftplan` baut auf `php84`, `composer.json` verlangt `^8.5`.
3. **Drift:** `craftplan/staging.Dockerfile` baut imagick per `pecl` (statt Source) und ohne `brotli`; die sechs Dateien sind über die Zeit auseinandergelaufen.

## 2. Ziele / Nicht-Ziele

**Ziele**
- Deploy-Zeit senken, indem die Extension-Kompilierung **einmalig** in CI passiert statt bei jedem Deploy.
- Einheitliches, gepinntes, verlässliches Extension-Set über alle Projekte und Versionen.
- Abdeckung **PHP 8.2, 8.3, 8.4, 8.5**, jeweils **amd64 und arm64** (8 Images).
- Projekt-Dockerfiles auf ~3 Zeilen reduzieren.

**Nicht-Ziele**
- Kein Umstieg weg von Vapor/Lambda.
- Kein Zwang, produktive Umgebungen sofort auf arm umzustellen (arm wird nur *bereitgestellt*).
- Kein Chromium im Image (Browsershot läuft via Sidecar), kein `phpredis` (überall `predis`).

## 3. Architektur

Neues öffentliches Repo **`john-wink/vapor-base`** mit einer parametrisierten Basis-Dockerfile und einem GitHub-Actions-Matrix-Build. Die fertigen Images werden nach **GHCR** (und optional Docker Hub) gepusht. Projekte konsumieren sie per `FROM`.

```
laravelphp/vapor:phpXX[-arm]   (offizielle Vapor-Runtime-Basis)
        │  + gd/exif/imagick/gmp/brotli/excimer + ffmpeg + mysql-client + php.ini-Defaults
        ▼
ghcr.io/john-wink/vapor-base:phpXX[-arm]   (einmalig in CI gebaut)
        │  + COPY . /var/task
        ▼
Projekt-Image (pro vapor deploy, ohne Kompilierung)
```

### 3.1 Basis-Dockerfile (parametrisiert)

- `ARG VAPOR_TAG` — der exakte Vapor-Basis-Tag (z. B. `php85` oder `php85-arm`), vom Workflow aus der Matrix berechnet (Punkt entfernt, `-arm` je nach Arch angehängt).
- `FROM laravelphp/vapor:${VAPOR_TAG}` — hält die Dockerfile frei von Tag-String-Manipulation (die in Dockerfiles nicht möglich ist).
- Optional `ARG PHP_VERSION` (z. B. `8.5`) nur für Labels/Metadaten.
- Installiert die **Extension-Union** aller Projekte, einheitlich für alle Versionen:
  - Kompiliert/aktiviert: `gd` (freetype/jpeg/webp), `exif`, `imagick`, `gmp`, `brotli`, `excimer`
  - System: `ffmpeg`, `mysql-client`, `icu-data-full`/`icu-dev`, `tzdata`, musl-locales
- **imagick gepinnt:** bevorzugt ein stabiles `pecl`-Release, falls es die Ziel-PHP-Version unterstützt; sonst ein **fester Git-Tag** (kein `develop`/`master`). Der konkrete Ref wird beim ersten Matrix-Build ermittelt und dann festgeschrieben.
- **excimer** gilt als „best effort": falls es auf einer bestimmten Version/Arch nicht baut (finance-estate hatte es auf arm auskommentiert), darf es diesen Build **nicht** hart brechen — Verhalten wird beim Matrix-Build final entschieden und dokumentiert.
- Build-Abhängigkeiten (`${PHPIZE_DEPS}`, `*-dev`) werden nach dem Kompilieren wieder entfernt (schlankes Image).
- Sinnvolle `php.ini`-Defaults werden mitgeliefert; Projekte überschreiben weiterhin per `COPY ./php/conf.d/php.ini …/overrides.ini`.

### 3.2 Wichtig: nur ergänzen, was fehlt

Die heutigen Dockerfiles bauen nur `gd/exif/imagick/gmp/brotli(/excimer)` — `intl`, `zip`, `bcmath`, `pdo`, `fileinfo` sind offenbar bereits in der Vapor-Basis enthalten (es wird nur `icu-dev` als Runtime-Lib gesetzt, kein `docker-php-ext-install intl`). Der Build **verifiziert** das aktive Set per `php -m` und **schlägt fehl**, wenn eine benötigte Extension fehlt (`intl, zip, bcmath, gd, imagick, exif, gmp, brotli, pdo_mysql, fileinfo`). So kann kein Image ausgeliefert werden, dem ein Projekt etwas Nötiges fehlt.

### 3.3 CI-Workflow

- **Matrix:** PHP `{8.2, 8.3, 8.4, 8.5}` × Arch `{amd64, arm64}` = 8 Jobs.
- **Runner:** amd64-Jobs auf `ubuntu-latest`; **arm64-Jobs auf nativen `ubuntu-24.04-arm`-Runnern** (public repo = kostenlos). Grund: C-Extensions unter QEMU zu kompilieren wäre 10–20× langsamer.
- **Tags:** exakt Vapor-Konvention — `php82`, `php82-arm`, …, `php85`, `php85-arm`.
- **Registry:** GHCR (`ghcr.io/john-wink/vapor-base`) immer; Docker Hub zusätzlich, wenn Secrets vorhanden (resilientes Muster wie bei `laravel-ci`).
- **Trigger:** Push auf `main` (bei Änderung an Dockerfile/Workflow), `workflow_dispatch`, wöchentlich (`schedule`) für Sicherheitsupdates der Vapor-Basis.
- **Verifikation:** `php -m`-Assertion (3.2) als eigener Build-Schritt.

### 3.4 Projekt-Dockerfile nach Migration

```dockerfile
# x86-Umgebung
FROM ghcr.io/john-wink/vapor-base:php85
COPY ./php/conf.d/php.ini /usr/local/etc/php/conf.d/overrides.ini
COPY . /var/task
```
Für arm-Umgebungen identisch mit `:php85-arm`. Damit verschwinden alle projektspezifischen Kompilier-Schritte.

## 4. Pilot & Rollout

**Pilot: `craftplan` staging.**
- Risikoarm (Staging), und behebt zugleich Mismatch (#2, 8.4→8.5) und Drift (#3).
- Ablauf: Basis-Image `php85`/`php85-arm` bauen → `craftplan/staging.Dockerfile` auf `FROM ghcr.io/john-wink/vapor-base:php85` umstellen → `vapor deploy staging` → verifizieren (Anwendung lädt, imagick/gd/pdf funktionieren).
- **Dieser Deploy validiert die tragende Annahme**, dass Vapor ein abgeleitetes Basis-Image (chained `FROM`) akzeptiert. Erst wenn der Pilot grün ist, folgt der Rollout.

**Rollout (nach erfolgreichem Pilot):** restliche craftplan-Umgebung, dann app-ys-consulting (prod/staging, Octane beachten), dann finance-estate (x86 + arm). Pro Umgebung: Dockerfile umstellen, deployen, verifizieren.

## 5. Risiken & Gegenmaßnahmen

| Risiko | Gegenmaßnahme |
|---|---|
| Vapor akzeptiert chained `FROM` nicht | Pilot-Deploy als früher Realtest; Fallback: Basis-Inhalte in eine projektlokale, aber vereinheitlichte Dockerfile inlinen (Ansatz B) |
| imagick/excimer bauen nicht auf jeder Version/Arch | Matrix zeigt es früh; imagick gepinnt, excimer best-effort/dokumentiert |
| arm-Runner nicht verfügbar/kontingentiert | Fallback QEMU-Build (langsam, aber funktioniert) |
| Octane (app-ys) verhält sich auf neuem Basis-Image anders | app-ys erst nach craftplan migrieren; eigene Staging-Verifikation |
| Fehlende Extension erst zur Laufzeit bemerkt | `php -m`-Assertion im Build (3.2) |

## 6. Manuelle Schritte (User)

1. Docker-Hub-Secrets `DOCKER_USERNAME` / `DOCKER_KEY` im neuen `vapor-base`-Repo hinterlegen (falls Docker-Hub-Push gewünscht).
2. GHCR-Paket ggf. auf public prüfen (bei public repo automatisch).
3. Für den Pilot-Deploy: Vapor-CLI + AWS-Credentials lokal verfügbar.

## 7. Offene Detailfragen (in der Implementierung zu klären)

- Konkreter imagick-Pin (pecl-Release vs. Git-Tag) — via erstem Matrix-Build ermitteln.
- Endgültiger Umgang mit `excimer` je Arch/Version.
- Genaue `php.ini`-Defaults im Basis-Image (aus den drei Projekt-`php.ini` zusammenführen).
