#!/usr/bin/env bash
# Обновление сайта до свежей версии из репозитория. Запускать от root: bash update.sh
# Перед заменой делает копию — откат одной командой, она печатается в конце.
set -euo pipefail

DOMAIN="knigaistory.ru"
REPO="dburlaku/vsemmirom"
BRANCH="main"
ROOT="/var/www/$DOMAIN"
STAMP=$(date +%Y%m%d-%H%M%S)
BACK="/var/backups/site-$DOMAIN-$STAMP"

mkdir -p "$BACK"
cp -a "$ROOT/." "$BACK/"
echo "Копия предыдущей версии: $BACK"

tmp=$(mktemp -d)
curl -fsSL "https://codeload.github.com/$REPO/tar.gz/refs/heads/$BRANCH" | tar xz -C "$tmp" --strip-components=1
took=0; missing=""
for f in index.html quiz.html app.html tokens.css heic-next.js \
         face-api.js \
         ssd_mobilenetv1_model-weights_manifest.json ssd_mobilenetv1_model.bin \
         face_landmark_68_model-weights_manifest.json face_landmark_68_model.bin \
         face_recognition_model-weights_manifest.json face_recognition_model.bin; do
  if [ -f "$tmp/$f" ]; then cp -f "$tmp/$f" "$ROOT/$f"; took=$((took+1)); else missing="$missing $f"; fi
done
echo "Обновлено файлов: $took"
if [ -n "$missing" ]; then echo "Нет в репозитории:$missing"; fi
rm -rf "$tmp"
chown -R www-data:www-data "$ROOT"
find "$ROOT" -type f -exec chmod 644 {} +

# Проверка отдачи. Раньше здесь был обычный curl на https://knigaistory.ru/ —
# и он всегда печатал 000: сервер не умеет ходить к собственному внешнему адресу
# (нет разворота NAT на себя), так что проверка молчала обо всём сразу.
# Ходим к самим себе на 127.0.0.1, подставляя имя домена через --resolve:
# nginx видит тот же Host и отдаёт тот же сайт, а сеть наружу не нужна.
echo
echo "Отдача сайта:"
bad=0
for f in "" quiz.html app.html; do
  u="https://$DOMAIN/$f"
  code=$(curl -sS -m 20 --resolve "$DOMAIN:443:127.0.0.1" -o /dev/null -w '%{http_code}' "$u" 2>/dev/null || echo 000)
  printf "  %-40s %s\n" "${u}" "$code"
  [ "$code" = 200 ] || bad=1
done

# И главное: то ли встало. Сверяем файл на диске с тем, что реально отдаётся —
# 27.09 на сервер дважды уезжала сборка на шаг старше, и заметить это было нечем.
echo
echo "Что встало:"
for f in app.html index.html; do
  [ -f "$ROOT/$f" ] || continue
  disk=$(sha256sum "$ROOT/$f" | cut -c1-16)
  served=$(curl -sS -m 20 --resolve "$DOMAIN:443:127.0.0.1" "https://$DOMAIN/$f" 2>/dev/null | sha256sum | cut -c1-16)
  bytes=$(stat -c%s "$ROOT/$f")
  if [ "$disk" = "$served" ]; then
    printf "  %-14s %9s байт  sha %s\n" "$f" "$bytes" "$disk"
  else
    printf "  %-14s %9s байт  НА ДИСКЕ %s, А ОТДАЁТСЯ %s — кеш или другой каталог\n" \
           "$f" "$bytes" "$disk" "$served"
    bad=1
  fi
done
if [ "$bad" = 1 ]; then
  echo
  echo "!! Сайт отдаётся не так, как ожидалось — смотрите строки выше."
fi

# оставляем последние 5 копий
ls -1dt /var/backups/site-$DOMAIN-* 2>/dev/null | tail -n +6 | xargs -r rm -rf

echo
echo "Откат: rm -rf $ROOT/* && cp -a $BACK/. $ROOT/ && chown -R www-data:www-data $ROOT"
