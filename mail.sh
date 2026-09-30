#!/usr/bin/env bash
# Почта «Всем миром». Запуск на сервере от root:  bash /root/mail.sh
# Скрипт спрашивает доступ к SMTP провайдера, проверяет записи домена,
# шлёт пробное письмо и только потом включает отправку.
# Пароль не печатается на экран, не попадает в историю команд и никуда,
# кроме /etc/vm-api.env, не уходит. Запускать можно повторно.
set -uo pipefail

ENVF=${ENVF:-/etc/vm-api.env}
DOMAIN=${DOMAIN:-knigaistory.ru}
say(){ printf "\n\033[1m== %s\033[0m\n" "$*"; }
ok(){  printf "  \033[32m%s\033[0m\n" "$*"; }
no(){  printf "  \033[31m%s\033[0m\n" "$*"; }
die(){ printf "\n\033[31mОстановился: %s\033[0m\n" "$*"; exit 1; }

[ "$(id -u)" = 0 ] || die "нужен root"
[ -f "$ENVF" ] || die "нет $ENVF — сначала bash /root/api-install.sh"
command -v dig >/dev/null || { apt-get update -qq && apt-get install -y dnsutils >/dev/null 2>&1; }

say "1/5 Кто отправляет"
cat <<'TXT'
Свой почтовый сервер на этой машине слать письма не будет: у VPS нет
репутации, и письма уйдут в спам — а «Книга в печати», попавшая в спам,
хуже, чем её отсутствие. Нужен провайдер рассылки с прогретыми адресами.

Российские, у всех есть SMTP и бесплатный объём на старте:
  Unisender Go   go.unisender.ru     — дешёвый транзакционный, простой старт;
                 суточного потолка нет, SPF include:spf.unisender.ru,
                 DKIM по селектору us
  RuSender       rusender.ru
  DashaMail      dashamail.ru
  Sendsay        sendsay.ru
  SendPulse      sendpulse.com

Почта на домене тоже подойдёт и на старте даже удобнее:
  Спринтхост        smtp.ВАШ-ДОМЕН:465 — 4 000 писем в сутки и 15 000 в
                    месяц, DKIM в той же панели, где бокс; услуга идёт с
                    тарифом хостинга, а не с боксом, и домен должен быть
                    делегирован на NS Спринтхоста
  Яндекс 360        smtp.yandex.ru:465 — 300 писем в сутки через SMTP,
                    DKIM подписывается сам после подтверждения домена
  Mail.ru бизнес    smtp.mail.ru:465

Суточный потолок у почты на домене жёсткий, и за превышение отправка
выключается на сутки целиком. Скрипт поставит наш собственный предел
чуть ниже, чтобы до чужого дело не доходило.

Что нужно от провайдера: адрес SMTP-сервера, порт, логин, пароль
и подтверждённый адрес отправителя на вашем домене.
TXT
printf "\nПродолжить? [Enter] "; read -r _

say "2/5 Доступ к SMTP"
read -rp "  Сервер (например smtp.go.unisender.ru): " M_HOST
read -rp "  Порт [465]: " M_PORT; M_PORT=${M_PORT:-465}
read -rp "  Логин: " M_USER
printf "  Пароль (ввод не отображается): "; IFS= read -rs M_PASS; echo
read -rp "  Адрес отправителя [kniga@$DOMAIN]: " M_FROM; M_FROM=${M_FROM:-kniga@$DOMAIN}
read -rp "  Имя отправителя [Всем миром]: " M_NAME; M_NAME=${M_NAME:-Всем миром}
read -rp "  Адрес для ответов (Reply-To), можно пусто: " M_REPLY
# У почты на домене суточный потолок жёсткий: Яндекс 360 — 300 писем через SMTP,
# и попытка отправить во время блокировки продлевает её ещё на сутки. Поэтому
# останавливаемся сами, не доходя до чужого предела.
case "$M_HOST" in
  *yandex*) CAP=250;;
  *mail.ru*) CAP=250;;
  smtp."$DOMAIN"|*sprinthost*) CAP=450;;   # 15 000 в месяц важнее, чем 4 000 в сутки
  *) CAP=0;;
esac
if [ "$CAP" != 0 ]; then
  echo "  Это почта на домене: ставлю свой суточный предел $CAP писем,"
  echo "  чтобы не упереться в лимит провайдера и не получить блокировку на сутки."
fi
read -rp "  Свой суточный предел писем, 0 — без учёта [$CAP]: " M_DAILY; M_DAILY=${M_DAILY:-$CAP}
[ -n "$M_HOST" ] && [ -n "$M_USER" ] && [ -n "$M_PASS" ] || die "сервер, логин и пароль обязательны"
case "$M_PORT" in 465) M_SECURE=1;; *) M_SECURE=0;; esac

say "3/5 Записи домена"
# Без SPF, DKIM и DMARC письма уходят в спам даже у хорошего провайдера.
# Проверяем то, что видно снаружи; ключ DKIM даёт провайдер, селектор у всех свой.
SPF=$(dig +short TXT "$DOMAIN" 2>/dev/null | tr -d '"' | grep -i 'v=spf1' | head -1)
if [ -n "$SPF" ]; then ok "SPF есть: $SPF"; else
  no "SPF нет. Добавьте TXT-запись на $DOMAIN:"
  case "$M_HOST" in
    *unisender*) echo "     v=spf1 include:spf.unisender.ru ~all";;
    *yandex*) echo "     v=spf1 redirect=_spf.yandex.net";;
    *mail.ru*) echo "     v=spf1 include:_spf.mail.ru ~all";;
    smtp."$DOMAIN"|*sprinthost*) echo "     v=spf1 include:_spf.sprinthost.ru ~all   (точное значение — в панели, раздел Почта)";;
    *) echo '     v=spf1 include:<домен-провайдера> ~all';;
  esac
  echo "     SPF-запись у домена может быть только одна. Если ящик для ответов"
  echo "     живёт у другого провайдера и вы отвечаете из него — допишите его"
  echo "     include в эту же строку, а не заводите вторую запись."
fi
DMARC=$(dig +short TXT "_dmarc.$DOMAIN" 2>/dev/null | tr -d '"' | grep -i 'v=DMARC1' | head -1)
if [ -n "$DMARC" ]; then ok "DMARC есть: $DMARC"; else
  no "DMARC нет. Добавьте TXT-запись на _dmarc.$DOMAIN:"
  echo "     v=DMARC1; p=none; rua=mailto:postmaster@$DOMAIN"
fi
DKIM_OK=""
for s in us mail default dkim selector1 selector2 uni sendsay dm; do
  v=$(dig +short TXT "$s._domainkey.$DOMAIN" 2>/dev/null | head -1)
  [ -n "$v" ] && { ok "DKIM найден по селектору «$s»"; DKIM_OK=1; break; }
done
[ -z "$DKIM_OK" ] && no "DKIM не найден — возьмите запись в панели провайдера и добавьте её в DNS"
if [ -z "$SPF" ] || [ -z "$DMARC" ] || [ -z "$DKIM_OK" ]; then
  printf "\n  Записи можно дописать позже, но до них письма будут попадать в спам.\n"
  printf "  Продолжить настройку? [y/N] "; read -r a; case "$a" in y|Y|д|Д) ;; *) die "остановлено, добавьте записи и запустите снова";; esac
fi

say "4/5 Пробное письмо"
read -rp "  Куда отправить проверку [$M_FROM]: " M_TEST; M_TEST=${M_TEST:-$M_FROM}
MAIL_HOST="$M_HOST" MAIL_PORT="$M_PORT" MAIL_SECURE="$M_SECURE" \
MAIL_USER="$M_USER" MAIL_PASS="$M_PASS" MAIL_FROM="$M_FROM" MAIL_FROM_NAME="$M_NAME" \
node -e '
const { buildMime, smtpSend } = require("/opt/vm-api/mail.js");
const to = process.argv[1];
const mime = buildMime(to, "Проверка почты «Всем миром»",
  "Если вы читаете это письмо, отправка настроена.\n\nПроверьте две вещи:\n" +
  "1) письмо лежит во «Входящих», а не в спаме;\n" +
  "2) отправитель показан как «" + (process.env.MAIL_FROM_NAME||"") + "», а не как набор букв.",
  null, {});
smtpSend(to, mime).then(r => { console.log("  ответ сервера:", r.trim()); process.exit(0); })
  .catch(e => { console.error("  ОШИБКА:", e && e.message); process.exit(1); });
' "$M_TEST" || die "письмо не ушло — проверьте сервер, порт, логин и пароль"
ok "письмо отправлено на $M_TEST"
printf "\n  Дошло? Посмотрите ящик, включая «Спам». Записать настройки? [y/N] "
read -r a; case "$a" in y|Y|д|Д) ;; *) die "не записал — настройки остались прежними";; esac

say "5/5 Запись настроек и перезапуск"
cp "$ENVF" "$ENVF.bak.$(date +%s)"
sed -i '/^MAIL_/d;/^SITE_URL=/d' "$ENVF"
{
  echo "MAIL_HOST=$M_HOST"
  echo "MAIL_PORT=$M_PORT"
  echo "MAIL_SECURE=$M_SECURE"
  echo "MAIL_USER=$M_USER"
  echo "MAIL_PASS=$M_PASS"
  echo "MAIL_FROM=$M_FROM"
  echo "MAIL_FROM_NAME=$M_NAME"
  echo "MAIL_DAILY=$M_DAILY"
  [ -n "$M_REPLY" ] && echo "MAIL_REPLY=$M_REPLY"
  echo "SITE_URL=https://$DOMAIN"
} >> "$ENVF"
chmod 600 "$ENVF"
unset M_PASS
ok "записал в $ENVF (права 600, копия прежнего файла рядом)"

systemctl restart vm-api
sleep 3
systemctl is-active vm-api >/dev/null || { journalctl -u vm-api -n 30 --no-pager; die "сервис не поднялся"; }
H=$(curl -sS -m 20 http://127.0.0.1:8081/api/health)
echo "  $H"
case "$H" in
  *'"mail":true'*) printf "\n\033[32mГотово. Письма включены.\033[0m\n";;
  *) die "сервис поднялся, но почта выключена — посмотрите journalctl -u vm-api -n 30";;
esac

cat <<TXT

Что теперь происходит само:
  • при создании заказа владельцу уходит письмо со ссылкой на книгу;
  • за три дня и за день до закрытия сбора — напоминание владельцу
    и тем участникам, кто оставил почту и ещё ничего не прислал;
  • «сбор закрыт», «книга в печати», «книга отправлена» с трек-номером;
  • «Отправить приглашения» рассылает личные ссылки тем, у кого есть почта.

Если писем станет больше, чем разрешает провайдер, они не потеряются:
очередь дождётся следующих суток. Но это знак, что пора переходить на
транзакционного провайдера — там потолка нет.

Посмотреть очередь и разобраться, если письмо не дошло:
  su postgres -c "psql -d vm -c \"select kind,addr,status,attempts,left(last_error,60) from mail order by id desc limit 20\""

Журнал отправки:
  journalctl -u vm-api -n 50 --no-pager | grep '\[mail\]'
TXT
