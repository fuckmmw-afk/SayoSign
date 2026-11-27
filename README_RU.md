<p align="center">
  <img src="docs/assets/icon.png" width="128" alt="Иконка SayoSign">
</p>

<h1 align="center">SayoSign</h1>

<p align="center">
  <b>Милый и очень мощный подписыватель IPA прямо на iPhone.</b><br>
  Подпись через .p12 или бесплатный Apple ID, инжект твиков своим движком хуков, установка без компьютера и интернета.
</p>

<p align="center">
  <a href="https://github.com/murk-sus/SayoSign/actions"><img src="https://github.com/murk-sus/SayoSign/actions/workflows/build.yml/badge.svg" alt="Build"></a>
  <img src="https://img.shields.io/badge/iOS-15%2B-ff7e8a" alt="iOS 15+">
  <img src="https://img.shields.io/badge/license-GPL--3.0-f0566e" alt="GPL-3.0">
  <a href="README.md"><img src="https://img.shields.io/badge/README-English-ffb3a7" alt="English"></a>
  <a href="README_ZH.md"><img src="https://img.shields.io/badge/README-简体中文-ffb3a7" alt="Chinese"></a>
</p>

---

## ✨ Возможности

- **Подпись прямо на устройстве.** Собственный движок на C, написанный с нуля, без OpenSSL и zsign внутри. Он умеет:
  - Mach-O, в том числе fat-бинарники;
  - CodeDirectory на SHA-256 и CMS-подпись;
  - entitlements в XML и DER;
  - вложенные фреймворки и расширения, `_CodeSignature/CodeResources`;
  - упаковку IPA в ZIP64.
- **Сертификаты.** Импорт `.p12` вместе с `.mobileprovision`. Видны команда, срок действия, устройства и entitlements, а **отзыв проверяется в реальном времени через OCSP** Apple.
- **Вход через Apple ID.** Работает с бесплатным или платным аккаунтом разработчика. SayoSign сам проходит GrandSlam: SRP-6a и 2FA через доверенное устройство или SMS. Затем через Apple Developer Services регистрирует устройство, создаёт сертификат и для каждого приложения на лету получает профиль.
- **Инжект твиков.** Поддерживаются `.dylib`, `.deb` (gzip, xz, lzma, zstd; для zstd свой декодер) и `.framework`. Зависимости Substrate, ElleKit, libhooker и substitute переподключаются автоматически.
- **SayoHook.** Свой фреймворк хуков, который ставится как `CydiaSubstrate.framework`. Экспортирует `MSHookMessageEx`, `MSHookFunction`, `MSFindSymbol`, `MSGetImageByName`, `LHHookFunctions`, `LBHookMessage` и `substitute_*`.
  - Хуки Objective-C работают везде.
  - Хуки C-функций на стоковой iOS работают через перепривязку указателей символов. При доступном JIT используются настоящие inline-трамплины ARM64 с релокацией инструкций.
- **Установка без интернета.** Приложение ставится через маленький HTTPS-сервер на `localhost` и `itms-services`. Доверие обеспечивает центр сертификации, созданный на твоём устройстве; его ключ никогда не покидает телефон. Никаких утёкших ключей и чужих серверов.
- **Источники.** Репозитории AltStore, SideStore, Feather и ESign: поиск, скриншоты, скачивание в одно касание.
- **Правка приложений.** Можно сменить имя, bundle ID, версию, иконку и минимальную iOS, удалить расширения, Watch-приложение и URL-схемы, включить доступ через «Файлы» и добавить свои entitlements.
- **Интерфейс.** Розово-коралловый дизайн с бантиком 🎀, Liquid Glass на iOS 26+, темы Светлая / Чёрная / Системная, английский, русский и китайский языки.

## 🍎 Apple ID и anisette в 2026

С середины октября 2026 Apple отклоняет anisette с **Android**-библиотек (`ani.sidestore.io`, `ani.sidestore.zip`, свой `anisette-v3-server`): ошибки `-80045`, HTTP `503`, `401`. В SayoSign 1.1 — протокол **anisette v3**, client info сервера во всех запросах к Apple, Mac-серверы по умолчанию с автопереездом с отклонённых, проверка сервера в **Настройки → Anisette-сервер → Проверить сервер** и понятные коды ошибок. Есть ПК? **[SayoSign Desktop](https://github.com/murk-sus/SayoSign-Desktop)** поднимет anisette-сервер на компьютере — отсканируй его QR камерой айфона.

## 🖥 Десктоп

Подпись с Linux, Windows и macOS переехала в отдельный репозиторий: **[SayoSign Desktop](https://github.com/murk-sus/SayoSign-Desktop)**.

## 📲 Установка

1. Скачай `SayoSign.ipa` из [Releases](https://github.com/murk-sus/SayoSign/releases) или последнюю сборку из [Actions](https://github.com/murk-sus/SayoSign/actions).
2. Один раз подпиши его чем угодно: другим подписывателем, Sideloadly, AltStore или CLI `sayosign` из этого репозитория.
3. Открой SayoSign → **Настройки → Настройка установщика** и пройди три шага. Это делается один раз.

## 🛠 Подпись с компьютера

Тот же движок собирается как CLI (Linux или macOS; для чтения p12 нужен OpenSSL):

```sh
make
./build/sayosign sign -k cert.p12 -p 1234 -m profile.mobileprovision -i app.ipa -o signed.ipa \
    -n "Моё приложение" -l tweak.deb -H build/CydiaSubstrate.framework
./build/sayosign ocsp -k cert.p12 -p 1234
```

## 🧱 Сборка

Всё собирается в GitHub Actions, Mac не нужен.

- `make && ./tests/run.sh` собирает ядро и запускает тесты: zstd, ZIP64, .deb, а также SRP-6a, AES-GCM и PBKDF2, которые сверяются с эталонными реализациями.
- `xcodegen generate`, затем `xcodebuild …` собирают неподписанный IPA (см. `.github/workflows/build.yml`).

## 🧾 Источник для AltStore

Добавь `https://murk-sus.github.io/SayoSign/source.json` в AltStore, SideStore, Feather или в сам SayoSign.

## 🧩 Твики в источниках

Источник может отдавать не только .ipa, но и твики (.dylib / .deb). SayoSign показывает их на вкладке «Твики» в «Источниках», сам скачивает новые версии при обновлении источников (раз в 30 минут при открытии приложения или по свайпу вниз) и сам добавляет твик при подписи приложения, для которого он сделан.

Три способа описать твик — другие подписчики эти поля просто игнорируют:

```json
{
  "name": "Мой репо",
  "apps": [
    {
      "name": "Telegram", "bundleIdentifier": "ph.telegra.Telegraph",
      "downloadURL": "https://example.com/Telegram.ipa", "version": "12.2",
      "tweaks": [
        { "name": "MyTweak", "identifier": "com.me.mytweak", "version": "1.4",
          "downloadURL": "https://example.com/mytweak.dylib" }
      ]
    },
    { "name": "Другой твик", "identifier": "com.me.other", "version": "2.0",
      "downloadURL": "https://example.com/other.dylib", "targets": ["com.spotify.client"] }
  ],
  "tweaks": [
    { "name": "Общий твик", "identifier": "com.me.any", "version": "0.3",
      "downloadURL": "https://example.com/any.deb", "targets": ["*"],
      "versions": [{ "version": "0.3", "date": "2026-11-23", "downloadURL": "https://example.com/any.deb" }] }
  ]
}
```

- `tweaks` внутри приложения — твик для этого приложения (`targets` по умолчанию — его bundle ID);
- запись в `apps` с файлом `.dylib`/`.deb` (или `"type": "tweak"`) считается твиком;
- верхнеуровневый `tweaks` с `targets` (bundle ID или `"*"` — подходит любому, но сам не подключается).

Обновление определяется по `identifier`: если поменялись `version` или ссылка, файл скачивается заново. Отключить можно в Настройках → «Твики из источников» или для одного твика долгим нажатием.

## ☁️ Подпись на своём сервере

SayoSign может подписывать на вашем сервере вместо iPhone: **Настройки → Сервер подписи** или переключатель **iPhone / Сервер** в окне подписи.

- Сервер сам скачивает IPA по ссылке из источника. Приложения, импортированные из «Файлов», загружаются частями по 16 МБ: так работает и за Cloudflare, и загрузка продолжается после обрыва связи.
- Твики и хук-фреймворк загружаются один раз и дальше находятся по контрольной сумме. Уже вшитые твики по-прежнему можно убрать или заменить, работают все опции локальной подписи.
- iOS ставит подписанное приложение прямо с сервера по manifest, локальный установщик не нужен. Копия также скачивается в «Подписанные», а сервер удаляет свою через 24 часа.
- Сертификат (ключ с сертификатом или .p12) передаётся на каждую подпись и удаляется после неё. Профили Apple ID по-прежнему запрашиваются на iPhone.

Установка сервера (Linux с nginx и Python 3, без дополнительных пакетов): `sudo server/install.sh https://example.com/sign`, добавьте `server/nginx.conf` в конфиг сайта и откройте на iPhone напечатанную ссылку `sayosign://server?url=…&key=…`. API описан в начале `server/sayosign_server.py`.

## 🔍 Ещё

[IPALens](https://murk-sus.github.io/IPALens/?lang=ru) — проверка IPA, .p12, профиля или .deb прямо в браузере: расшифрован ли, есть ли UDID в профиле, подходит ли p12 к профилю.

## 💖 Поддержать

SayoSign бесплатный и открытый. Если он тебе помог, можно закинуть на чай:

| Сеть | Адрес |
|---|---|
| USDT (TRC20) | `TCPD7jzSMtQ4zkoSxSbUZi6RFoVdKqv78w` |
| TON | `UQAVaWTuYuEF8A_qiVEcHnqhomp2UdYvW4fHxyhJVxFkQe1z` |
| BTC | `bc1qqvt25c9tzw2yfdpvf738gzzk4r5uyvkrrlz4z0` |
| ETH (ERC20) | `0xE7497CF78B691F84D2f1A2Dc30223BB53B3EF38D` |
| SOL | `DhcDnnqK23gwvkRRHtNd3TBXN9gHmT4V7LZrAPHgCR6n` |

Страница с QR-кодами: **[murk-sus.github.io/donate](https://murk-sus.github.io/donate/)** · Telegram-канал: [@jailbreak_IOS_and_tweaks](https://t.me/jailbreak_IOS_and_tweaks)

## ⚖️ Правовое

SayoSign подписывает приложения **твоими** сертификатами для **твоих** устройств. Не используй его для распространения пиратского софта. Проект не связан с Apple.

Название — отсылка к Сайори. Арт из *Doki Doki Literature Club* не используется. Иконка собрана из [Twemoji](https://github.com/jdecked/twemoji) 🎀 ✒️ (CC-BY 4.0).

Лицензия **GPL-3.0**.
