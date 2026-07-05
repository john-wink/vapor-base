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

Gebaut via GitHub Actions (Matrix PHP × Arch). Siehe [`.github/workflows/build.yml`](.github/workflows/build.yml).
