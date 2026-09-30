"use strict";
/* Почта «Всем миром».

   Зависимостей нет намеренно: в проекте уже так — подпись S3 написана руками,
   и тащить пакет ради ста строк SMTP не за чем. Всё, что нужно, есть в Node:
   tls для соединения и crypto для идентификатора письма.

   Устройство: письмо не уходит в момент действия, а кладётся в таблицу mail.
   Отдельный цикл раз в полминуты забирает очередь и отправляет. Так заказ не
   падает из-за недоступного провайдера, а письмо не теряется при перезапуске
   сервиса. Повтор — с нарастающей паузой, шесть попыток, дальше строка
   помечается dead и остаётся видна в журнале.

   Свой SMTP на VPS почти гарантированно уедет в спам, поэтому здесь только
   клиент: адрес сервера, логин и пароль приходят от почтового провайдера
   через /etc/vm-api.env. */

const tls = require("node:tls");
const net = require("node:net");
const crypto = require("node:crypto");

const MAIL = {
  host: process.env.MAIL_HOST || "",
  port: +(process.env.MAIL_PORT || 465),
  user: process.env.MAIL_USER || "",
  pass: process.env.MAIL_PASS || "",
  from: process.env.MAIL_FROM || "",
  name: process.env.MAIL_FROM_NAME || "Всем миром",
  site: (process.env.SITE_URL || "https://knigaistory.ru").replace(/\/+$/, ""),
  reply: process.env.MAIL_REPLY || ""
};
/* 465 — шифрование с первого байта, 587 — обычное соединение и STARTTLS.
   Провайдеры иногда дают другие порты, поэтому режим можно задать явно. */
MAIL.secure = process.env.MAIL_SECURE ? process.env.MAIL_SECURE === "1" : MAIL.port === 465;
/* Дневной предел провайдера. У почты на домене он жёсткий: Яндекс 360 через
   SMTP — 300 писем в сутки, и при превышении отправка блокируется на сутки,
   а попытка отправить во время блокировки продлевает её ещё на сутки.
   Поэтому останавливаемся сами, не доходя до чужого предела. Ноль — без учёта
   (у транзакционных провайдеров такого потолка нет). */
MAIL.daily = Math.max(0, +(process.env.MAIL_DAILY || 0) || 0);
MAIL.ready = !!(MAIL.host && MAIL.user && MAIL.pass && MAIL.from);

/* ------------------------------------------------ адрес в свободном поле

   Поле «контакт» одно и свободное: туда пишут телефон, почту, «@ник в
   телеграме» или всё сразу. Достаём именно почту и не притворяемся, что
   разобрали остальное. */
const ПОЧТА = /[a-z0-9!#$%&'*+/=?^_`{|}~-]+(?:\.[a-z0-9!#$%&'*+/=?^_`{|}~-]+)*@(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}/i;
function emailOf(text) {
  const m = ПОЧТА.exec(String(text || ""));
  if (!m) return "";
  const a = m[0].toLowerCase();
  // ru-домены в кириллице сюда не попадут — и не надо: SMTP их без IDN не примет
  return a.length <= 254 ? a : "";
}
const looksLikeEmail = t => !!emailOf(t);

/* ------------------------------------------------ сборка письма

   Кириллица в теме и в теле кодируется base64: quoted-printable читаемее, но
   ошибиться в нём проще, а выигрыша никакого. */
const b64 = s => Buffer.from(String(s), "utf8").toString("base64");
const encHeader = s => /[^\x20-\x7E]/.test(s) ? "=?UTF-8?B?" + b64(s) + "?=" : s;
const addr = (a, n) => n ? encHeader(n) + " <" + a + ">" : a;

function buildMime(to, subject, text, html, extra) {
  const id = "<" + crypto.randomUUID() + "@" + (MAIL.from.split("@")[1] || "localhost") + ">";
  const bound = "b" + crypto.randomBytes(12).toString("hex");
  const h = [
    "From: " + addr(MAIL.from, MAIL.name),
    "To: " + to,
    "Subject: " + encHeader(subject),
    "Message-ID: " + id,
    "Date: " + new Date().toUTCString(),
    "MIME-Version: 1.0"
  ];
  if (MAIL.reply) h.push("Reply-To: " + MAIL.reply);
  for (const [k, v] of Object.entries(extra || {})) if (v) h.push(k + ": " + v);
  let body;
  if (html) {
    h.push('Content-Type: multipart/alternative; boundary="' + bound + '"');
    body = [
      "--" + bound,
      "Content-Type: text/plain; charset=UTF-8",
      "Content-Transfer-Encoding: base64", "", b64(text), "",
      "--" + bound,
      "Content-Type: text/html; charset=UTF-8",
      "Content-Transfer-Encoding: base64", "", b64(html), "",
      "--" + bound + "--", ""
    ].join("\r\n");
  } else {
    h.push("Content-Type: text/plain; charset=UTF-8");
    h.push("Content-Transfer-Encoding: base64");
    body = b64(text);
  }
  return h.join("\r\n") + "\r\n\r\n" + body + "\r\n";
}

/* ------------------------------------------------ разговор с SMTP

   Протокол простой и строчный: сервер отвечает трёхзначным кодом, 2xx и 3xx —
   можно дальше, всё остальное — ошибка. Единственная тонкость: многострочный
   ответ («250-PIPELINING», «250 OK») дочитываем до строки, где после кода
   пробел, а не дефис. */
function smtpTalk(sock, timeoutMs) {
  let буфер = "";
  let ждут = null;
  const разбор = () => {
    if (!ждут) return;
    const строки = буфер.split("\r\n");
    for (let i = 0; i < строки.length - 1; i++) {
      const s = строки[i];
      if (/^\d{3} /.test(s)) {
        const ответ = строки.slice(0, i + 1).join("\n");
        буфер = строки.slice(i + 1).join("\r\n");
        const w = ждут; ждут = null;
        clearTimeout(w.t);
        const код = +s.slice(0, 3);
        if (код >= 200 && код < 400) w.ok(ответ);
        else w.bad(Object.assign(new Error("SMTP " + ответ.slice(0, 200)), { code: "smtp", smtp: код }));
        return;
      }
    }
  };
  sock.setEncoding("utf8");
  sock.on("data", d => { буфер += d; разбор(); });
  const читать = () => new Promise((ok, bad) => {
    ждут = { ok, bad, t: setTimeout(() => { ждут = null; bad(Object.assign(new Error("SMTP не ответил"), { code: "timeout" })); }, timeoutMs) };
    разбор();
  });
  const слать = line => new Promise((ok, bad) => sock.write(line + "\r\n", e => e ? bad(e) : ok()));
  const шаг = async line => { await слать(line); return читать(); };
  return { читать, слать, шаг };
}

async function smtpSend(to, mime, opts) {
  const o = Object.assign({ timeout: 25000 }, opts || {});
  const прямой = MAIL.secure;
  let sock = await new Promise((ok, bad) => {
    const s = (прямой ? tls : net).connect(
      прямой ? { host: MAIL.host, port: MAIL.port, servername: MAIL.host } : { host: MAIL.host, port: MAIL.port },
      () => ok(s));
    s.setTimeout(o.timeout, () => s.destroy(Object.assign(new Error("SMTP молчит"), { code: "timeout" })));
    s.once("error", bad);
  });
  let t = smtpTalk(sock, o.timeout);
  try {
    await t.читать();                                // приветствие
    const имя = (MAIL.from.split("@")[1] || "localhost");
    let ehlo = await t.шаг("EHLO " + имя);
    if (!прямой) {
      if (!/STARTTLS/i.test(ehlo)) throw Object.assign(new Error("сервер не предлагает STARTTLS"), { code: "notls" });
      await t.шаг("STARTTLS");
      sock = await new Promise((ok, bad) => {
        const s = tls.connect({ socket: sock, servername: MAIL.host }, () => ok(s));
        s.once("error", bad);
      });
      sock.setTimeout(o.timeout, () => sock.destroy(Object.assign(new Error("SMTP молчит"), { code: "timeout" })));
      t = smtpTalk(sock, o.timeout);
      ehlo = await t.шаг("EHLO " + имя);
    }
    if (/AUTH[ =-].*PLAIN/i.test(ehlo)) {
      await t.шаг("AUTH PLAIN " + Buffer.from("\0" + MAIL.user + "\0" + MAIL.pass, "utf8").toString("base64"));
    } else {
      await t.шаг("AUTH LOGIN");
      await t.шаг(Buffer.from(MAIL.user, "utf8").toString("base64"));
      await t.шаг(Buffer.from(MAIL.pass, "utf8").toString("base64"));
    }
    await t.шаг("MAIL FROM:<" + MAIL.from + ">");
    await t.шаг("RCPT TO:<" + to + ">");
    await t.шаг("DATA");
    // точка в начале строки — конец письма, поэтому её удваивают
    await t.слать(mime.replace(/\r?\n/g, "\r\n").replace(/^\./gm, "..") + "\r\n.");
    const ответ = await t.читать();
    try { await t.шаг("QUIT"); } catch (_) {}
    return ответ.slice(0, 120);
  } finally {
    try { sock.destroy(); } catch (_) {}
  }
}

/* ------------------------------------------------ очередь

   queueMail кладёт письмо и ничего не отправляет. Дубли отсекает uniq:
   «заказ создан» уйдёт один раз, даже если обработчик дёрнут повторно. */
async function queueMail(db, m) {
  const to = emailOf(m.to);
  if (!to) return { skipped: "нет адреса" };
  if (m.kind !== "owner-link") {                     // возврат ссылки шлём всегда
    const off = await db.query("select 1 from mail_off where addr=$1", [to]);
    if (off.rowCount) return { skipped: "отписан" };
  }
  const r = await db.query(
    `insert into mail(order_id,addr,kind,uniq,subject,body,html)
     values($1,$2,$3,$4,$5,$6,$7)
     on conflict (uniq) do nothing returning id`,
    [m.order || null, to, m.kind, m.uniq || null, m.subject, m.text, m.html || null]);
  if (!r.rowCount) return { skipped: "уже отправляли" };
  return { id: r.rows[0].id };
}

const ПАУЗА = [0, 60, 300, 900, 3600, 10800];        // секунды между попытками
const ПОПЫТОК = 6;
/* Отдельно от обычных ошибок: провайдер сказал «на сегодня хватит».
   Это не повод тратить попытки — это повод подождать до завтра. */
const ПРЕДЕЛ = /quota|limit exceeded|too many|rate limit|daily|550 5\.7\.1|451 4\.7|blocked|заблокирован/i;

async function mailTick(pool, limit = 20) {
  if (!MAIL.ready) return { off: true };
  const db = await pool.connect();
  let ушло = 0, битых = 0, осталось = Infinity;
  try {
    if (MAIL.daily) {
      const с = await db.query(
        "select count(*)::int n from mail where status='sent' and sent_at > now() - interval '24 hours'");
      осталось = MAIL.daily - с.rows[0].n;
      if (осталось <= 0) {
        console.error("[mail] дневной предел", MAIL.daily, "исчерпан — ждём");
        return { ушло: 0, предел: true };
      }
    }
    const r = await db.query(
      `select * from mail where status='queued' and send_after<=now()
       order by id limit $1`, [Math.min(limit, осталось)]);
    for (const row of r.rows) {
      // Отписка предлагается только в письмах участникам. Владельцу шлём
      // сервисные письма про его же заказ: «отписаться» от новости, что книга
      // ушла в печать, человек не хочет — он хочет её получить.
      const рассылка = /^invite/.test(row.kind);
      const extra = рассылка
        ? { "List-Unsubscribe": "<" + MAIL.site + "/api/mail/off?a=" + encodeURIComponent(row.addr) + ">",
            "List-Unsubscribe-Post": "List-Unsubscribe=One-Click" }
        : { "Auto-Submitted": "auto-generated" };
      try {
        await smtpSend(row.addr, buildMime(row.addr, row.subject, row.body, row.html, extra));
        await db.query("update mail set status='sent', sent_at=now(), attempts=attempts+1 where id=$1", [row.id]);
        ушло++;
      } catch (e) {
        const текст = String((e && e.message) || e);
        // Предел провайдера: не расходуем попытку и ждём сутки. Иначе цикл
        // сам продлевает чужую блокировку, стуча в закрытую дверь каждые полминуты.
        if (ПРЕДЕЛ.test(текст)) {
          await db.query(
            "update mail set last_error=$2, send_after=now() + interval '25 hours' where id=$1",
            [row.id, ("предел провайдера: " + текст).slice(0, 300)]);
          console.error("[mail] предел провайдера, ждём сутки:", текст.slice(0, 120));
          break;
        }
        const n = row.attempts + 1;
        const мёртвое = n >= ПОПЫТОК;
        await db.query(
          `update mail set attempts=$2, last_error=$3,
             status=$4, send_after=now() + ($5 || ' seconds')::interval where id=$1`,
          [row.id, n, String((e && e.message) || e).slice(0, 300),
           мёртвое ? "dead" : "queued", ПАУЗА[Math.min(n, ПАУЗА.length - 1)]]);
        if (мёртвое) битых++;
        console.error("[mail]", row.kind, row.addr, "попытка", n, (e && e.message) || e);
      }
    }
  } finally { db.release(); }
  return { ушло, битых };
}

module.exports = { MAIL, emailOf, looksLikeEmail, buildMime, smtpSend, queueMail, mailTick };
