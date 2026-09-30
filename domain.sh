#!/usr/bin/env bash
# Переезд сервиса на другой домен.  Запуск на сервере от root:  bash /root/domain.sh
#
# Меняет три вещи, которые знают старое имя: конфиг nginx, сертификат
# Let's Encrypt и SITE_URL в /etc/vm-api.env (из него берутся ссылки в письмах).
# Ничего не удаляет: старый конфиг остаётся на диске, копия env — рядом.
# Запускать можно повторно.
set -uo pipefail

ENVF=${ENVF:-/etc/vm-api.env}
say(){ printf "\n\033[1m== %s\033[0m\n" "$*"; }
ok(){  printf "  \033[32m%s\033[0m\n" "$*"; }
no(){  printf "  \033[31m%s\033[0m\n" "$*"; }
die(){ printf "\n\033[31mОстановился: %s\033[0m\n" "$*"; exit 1; }

[ "$(id -u)" = 0 ] || die "нужен root"
[ -f "$ENVF" ] || die "нет $ENVF — сначала bash /root/api-install.sh"

OLD=$(grep -m1 '^SITE_URL=' "$ENVF" | sed 's|^SITE_URL=https\?://||; s|/.*$||')
[ -n "$OLD" ] || OLD="knigaistorii.ru"

say "1/6 Какой домен"
echo "  Сейчас сервис живёт на: $OLD"
read -rp "  Новый домен: " NEW
NEW=$(echo "$NEW" | tr 'A-Z' 'a-z' | tr -d ' ')
case "$NEW" in
  ""|*/*|*" "*) die "так домен не выглядит";;
  *.*) ;;
  *) die "нужно полное имя, например knigaistory.ru";;
esac
[ "$NEW" = "$OLD" ] && die "это тот же самый домен"

say "2/6 Куда он указывает"
# Сертификат не выдадут, пока домен не смотрит на эту машину. Проверяем заранее,
# иначе certbot оставит после себя недонастроенный конфиг.
MYIP=$(curl -sS -m 10 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')
NEWIP=$(getent ahostsv4 "$NEW" | awk '{print $1; exit}')
NEWIPW=$(getent ahostsv4 "www.$NEW" | awk '{print $1; exit}')
echo "  этот сервер:      $MYIP"
echo "  $NEW:      ${NEWIP:-нет A-записи}"
echo "  www.$NEW:  ${NEWIPW:-нет A-записи}"
DNSOK=1
[ "$NEWIP" = "$MYIP" ] || { no "A-запись домена ведёт не сюда"; DNSOK=0; }
[ "$NEWIPW" = "$MYIP" ] || { no "A-запись www ведёт не сюда — www в сертификат не возьмём"; }
[ "$DNSOK" = 1 ] || die "сначала поправьте A-запись, разъезд DNS занимает часы"
ok "домен смотрит на этот сервер"
WITHWWW=0; [ "$NEWIPW" = "$MYIP" ] && WITHWWW=1

say "3/6 Конфиг nginx"
SRC=/etc/nginx/sites-available/$OLD
[ -f "$SRC" ] || die "не нашёл $SRC — посмотрите, как называется конфиг в /etc/nginx/sites-available"
DST=/etc/nginx/sites-available/$NEW
if [ -f "$DST" ]; then
  cp "$DST" "$DST.bak.$(date +%s)"
  echo "  конфиг уже был, сохранил копию"
fi
# Берём рабочий конфиг целиком и меняем в нём только имя. Так переносятся все
# правки, которые делались руками: лимиты, заголовки, пути к статике.
sed "s/\b$OLD\b/$NEW/g" "$SRC" > "$DST"
# Строки про старый сертификат убираем: его для нового имени нет, certbot впишет свой.
sed -i '/ssl_certificate/d;/ssl_certificate_key/d;/include .*options-ssl-nginx/d;/ssl_dhparam/d' "$DST"
# Слушать 443 без сертификата нельзя. Строки про 443 просто убираем — certbot
# впишет свои. Заменять их на «listen 80» нельзя: в блоке уже есть такая строка,
# а два одинаковых listen в одном server nginx считает ошибкой и не стартует.
sed -i '/listen 443 ssl/d;/listen \[::\]:443 ssl/d' "$DST"
grep -qE '^\s*listen\s+80\s*;|^\s*listen\s+\[::\]:80\s*;' "$DST" || \
  sed -i "0,/^\s*server_name/s//    listen 80;\n&/" "$DST"
if [ "$WITHWWW" = 1 ]; then
  sed -i "s/^\(\s*server_name\s\).*/\1$NEW www.$NEW;/" "$DST"
else
  sed -i "s/^\(\s*server_name\s\).*/\1$NEW;/" "$DST"
fi

# Каталог сайта назван по домену, и в конфиге он тоже переименовался. Если его
# не перенести, nginx будет искать несуществующую папку и отдавать 404 —
# и все последующие проверки покажут «сайт жив», потому что жив только nginx.
WWW=$(grep -m1 -E '^\s*root\s' "$DST" | sed 's/^\s*root\s\+//; s/;.*$//')
WWWOLD=$(grep -m1 -E '^\s*root\s' "$SRC" | sed 's/^\s*root\s\+//; s/;.*$//')
if [ -n "$WWW" ] && [ "$WWW" != "$WWWOLD" ]; then
  if [ -d "$WWW" ]; then
    ok "каталог сайта $WWW уже есть"
  elif [ -d "$WWWOLD" ]; then
    mv -n "$WWWOLD" "$WWW" && ok "каталог сайта перенесён: $WWWOLD -> $WWW"
    [ -d "$WWW" ] || die "не удалось перенести $WWWOLD в $WWW"
  else
    die "ни $WWWOLD, ни $WWW не существует — посмотрите, где лежит статика сайта"
  fi
fi

ln -sf "$DST" /etc/nginx/sites-enabled/$NEW
nginx -t || die "nginx не принял конфиг — посмотрите $DST"
systemctl reload nginx
if [ -n "$WWW" ]; then
  echo "  статика: $WWW ($(ls -1 "$WWW" 2>/dev/null | wc -l) файлов, app.html $([ -f "$WWW/app.html" ] && echo есть || echo НЕТ))"
fi
ok "сайт отвечает на $NEW по http"

say "4/6 Сертификат"
ARGS=(-d "$NEW"); [ "$WITHWWW" = 1 ] && ARGS+=(-d "www.$NEW")
ADMEMAIL=$(grep -m1 '^MAIL_FROM=' "$ENVF" | cut -d= -f2-)
certbot --nginx "${ARGS[@]}" --non-interactive --agree-tos \
  ${ADMEMAIL:+-m "$ADMEMAIL"} ${ADMEMAIL:---register-unsafely-without-email} --redirect \
  || die "certbot не выдал сертификат — обычно это значит, что DNS ещё не разъехался"
nginx -t && systemctl reload nginx
ok "https включён"

say "5/6 Ссылки в письмах"
# SITE_URL — это то, что человек увидит в письме и нажмёт. Если его не поменять,
# письма поведут на домен, которого у нас больше нет.
cp "$ENVF" "$ENVF.bak.$(date +%s)"
sed -i "s|^SITE_URL=.*|SITE_URL=https://$NEW|" "$ENVF"
grep -q '^SITE_URL=' "$ENVF" || echo "SITE_URL=https://$NEW" >> "$ENVF"
# адрес отправителя тоже мог быть на старом домене
if grep -q "^MAIL_FROM=.*@$OLD" "$ENVF"; then
  sed -i "s|^\(MAIL_FROM=[^@]*@\)$OLD|\1$NEW|" "$ENVF"
  ok "MAIL_FROM переписан на новый домен: $(grep -m1 '^MAIL_FROM=' "$ENVF" | cut -d= -f2-)"
  no "проверьте, что этот адрес подтверждён у провайдера рассылки — иначе письма перестанут уходить"
fi
chmod 600 "$ENVF"
systemctl restart vm-api
sleep 3
systemctl is-active vm-api >/dev/null || { journalctl -u vm-api -n 30 --no-pager; die "сервис не поднялся"; }
ok "записал и перезапустил"

say "6/6 Что получилось"
R="--resolve $NEW:443:127.0.0.1"
printf '  %-28s %s\n' 'health через nginx'  "$(curl -sk $R -o /dev/null -w '%{http_code}' https://$NEW/api/health)"
printf '  %-28s %s\n' 'страница app.html'   "$(curl -sk $R -o /dev/null -w '%{http_code}' https://$NEW/app.html)"
printf '  %-28s %s\n' 'главная'             "$(curl -sk $R -o /dev/null -w '%{http_code}' https://$NEW/)"
echo "  SITE_URL: $(grep -m1 '^SITE_URL=' "$ENVF" | cut -d= -f2-)"
echo "  сертификат: $(certbot certificates 2>/dev/null | grep -A1 "Certificate Name: $NEW" | grep Domains || echo 'посмотрите certbot certificates')"

cat <<TXT

Старый домен $OLD:
  конфиг остался в /etc/nginx/sites-available/$OLD и пока работает.
  Если доступа к нему больше нет — уберите его, чтобы не путался:
      rm -f /etc/nginx/sites-enabled/$OLD /etc/nginx/sites-enabled/$OLD-www
      nginx -t && systemctl reload nginx
  И снимите с обновления его сертификат, иначе certbot будет каждый день
  пытаться продлить то, чего нет, и слать ошибки в журнал:
      certbot delete --cert-name $OLD

Что важно помнить: ссылки, которые уже ушли людям в письмах, вели на
$OLD. Они будут работать ровно до тех пор, пока его A-запись
показывает сюда. Владельцам заказов ссылку можно выслать заново —
на странице «Мои книги» есть «Прислать ссылку на почту».
TXT
