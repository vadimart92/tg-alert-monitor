# TG Alert Monitor — специфікація для реалізації агентами

Версія 0.1 (чернетка на погодження). Дата: 2026-09-05.

---

## 0. Як користуватися цим документом

- Це єдине джерело вимог. Реалізація йде етапами M0–M4 (розділ 10); у кожного етапу є Definition of Done (DoD) і тести, які мають проходити перед переходом далі.
- Якщо факт у документі суперечить реальності (інша сигнатура API, інша версія пакета), правда за офіційною документацією і схемою `td_api.tl`. Розбіжність записується в розділ 13 «Журнал відхилень» тим самим комітом.
- Секрети (api_hash, bot token, номер телефону, код входу, пароль 2FA) вводить лише людина в UI застосунку. У код, у git, у логи вони не потрапляють ніколи.
- Мова UI: українська. Мова коду, ідентифікаторів, комітів: англійська.
- Кроки, позначені **[ЛЮДИНА]**, виконує власник, а не агент (прийняття ліцензій, отримання ключів, тести на реальному телефоні).

---

## 1. Мета і сценарій

Власник підписаний у Telegram на канали моніторингу повітряної тривоги і тримає їх у окремій папці (Telegram folder). Потрібен Android-застосунок, який:

1. Логіниться в Telegram **як користувач** (не бот: бот не бачить повідомлення чужих каналів).
2. Дає вибрати папку з каналами.
3. Дає задати список ключових слів (напр. `шахед`, `балістика`, `Бровари`).
4. Після натискання «Старт» **у фоні**, з вимкненим екраном і після перезавантаження телефону, читає нові повідомлення в чатах папки.
5. Якщо текст повідомлення містить ключове слово, надсилає його текст і посилання на оригінал у **цільовий канал від імені бота** (Bot API).

Сценарій використання: власник отримує швидке сповіщення, коли в моніторингових каналах пишуть про шахеди або ракети біля його дому.

---

## 2. Ключові рішення (зафіксовано)

| # | Рішення | Чому |
|---|---------|------|
| R1 | Клієнт Telegram: **TDLib** (офіційна бібліотека Telegram, JSON-інтерфейс через FFI) | Єдиний надійний спосіб читати канали від імені користувача на Android |
| R2 | Бінарники TDLib: готові `libtdjson.so` **v1.8.65** з [up9cloud/android-libtdjson](https://github.com/up9cloud/android-libtdjson/releases) (`jniLibs.tar.gz`, 42.8 МБ, реліз 2026-06-30) | Збірка TDLib із сирців потребує NDK, годин часу і >10 ГБ диска; на машині вільно 21 ГБ |
| R3 | Власна FFI-обгортка (~60 рядків) замість pub-пакета `libtdjson` | Пакет `libtdjson` тягне .so з GitHub Packages Maven, що вимагає `GITHUB_TOKEN` при кожній збірці. Копіювання .so у `jniLibs` простіше і без токена |
| R4 | Фон: **foreground service** через `flutter_foreground_task` ^11.0.2, TDLib живе **тільки в ізоляті сервісу** | Ізолят UI гине, коли користувач змахує застосунок з «Останніх»; ізолят сервісу живе далі. Два TDLib-клієнти на одній БД не допускаються, тому клієнт один і він у сервісі |
| R5 | Тип foreground-сервісу: **`specialUse`** | На Android 15+ сервіси типу `dataSync` система зупиняє після 6 годин на добу. `specialUse` без ліміту; для особистого (sideload) застосунку обґрунтування для Play не потрібне |
| R6 | Вихід: **Bot API `sendMessage`** у цільовий канал, текст + посилання на оригінал | Справжнє «переслати» від бота неможливе (бот не має доступу до джерела). Медіа не переносимо, лише підпис |
| R7 | Збіг ключового слова = **підрядок без урахування регістру** | Українські словоформи (`шахед`, `шахеди`, `шахедів`) покриваються одним коренем; regex не потрібен |
| R8 | Один акаунт, лише Android, без iOS/web | Особистий інструмент |

---

## 3. Архітектура

```
┌─────────────────────────── Android процес застосунку ───────────────────────────┐
│                                                                                  │
│  UI-ізолят (Flutter, Activity)             Ізолят foreground-сервісу             │
│  ┌──────────────────────────┐   JSON      ┌───────────────────────────────────┐  │
│  │ Екрани:                  │ команди     │ MonitorTaskHandler                │  │
│  │  Налаштування            │ ──────────▶ │   └ MonitorEngine (чиста логіка)  │  │
│  │  Логін                   │             │       ├ AuthFlow                  │  │
│  │  Головна (папка, слова,  │ ◀────────── │       ├ FolderResolver            │  │
│  │    старт/стоп, статус)   │  JSON       │       ├ MessagePipeline           │  │
│  │  Журнал збігів           │  події      │       │   └ KeywordMatcher        │  │
│  └──────────────────────────┘             │       └ ForwardQueue → BotApi ────┼──┼──▶ api.telegram.org (HTTPS)
│   SharedPreferences (конфіг)              │   TdClient (запит/відповідь, потік │  │
│   matches.jsonl (журнал, читає)           │     оновлень)                     │  │
│                                           │     └ receive-ізолят: td_receive  │  │
│                                           │          (блокуючий виклик)       │  │
│                                           │   libtdjson.so ◀──────────────────┼──┼──▶ Telegram MTProto
│                                           └───────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────────────────────┘
```

Потік даних під час моніторингу:

1. TDLib отримує `updateNewMessage`.
2. `MessagePipeline` фільтрує: чат у вибраній папці, не вихідне, є текст/підпис, не старіше `maxAge`, не дублікат.
3. `KeywordMatcher` шукає ключові слова.
4. При збігу: запис у `matches.jsonl`, подія `match` в UI, завдання у `ForwardQueue`.
5. `ForwardQueue` послідовно шле через Bot API з дотриманням лімітів і повторами.

Правило володіння: **TDLib-клієнт створюється лише в ізоляті сервісу**. UI ніколи не відкриває `libtdjson.so`.

---

## 4. Стек і версії

| Компонент | Версія | Примітка |
|-----------|--------|----------|
| Flutter | 3.47.2 stable (Dart 3.13.2) | Встановлено на цій машині в `E:\flutter` |
| Android minSdk / targetSdk | 26 / за замовчуванням шаблону Flutter (35) | minSdk 26: канали сповіщень, стабільний FGS |
| TDLib | 1.8.65 (up9cloud prebuilt) | ABI: `arm64-v8a`, `armeabi-v7a`, `x86_64`. `x86` не пакуємо (Flutter його не підтримує) |
| `flutter_foreground_task` | ^11.0.2 | Потребує Flutter ≥3.44 |
| `ffi` | ^2.1.0 | |
| `path_provider` | ^2.1.0 | Каталоги для БД TDLib |
| `shared_preferences` | ^2.5.0 | Конфіг |
| `http` | ^1.2.0 | Bot API; у тестах `package:http/testing.dart` `MockClient` |
| dev: `flutter_lints`, `flutter_test` | | Без mock-бібліотек: фейки пишемо руками |

Без bloc/riverpod: `ChangeNotifier` + `ListenableBuilder`. Мінімум залежностей.

Пакет/applicationId: `com.vadimart.tgalertmonitor` (змінити за бажанням власника до M0). Назва проєкту Dart: `tg_alert_monitor`.

---

## 5. Середовище на цій машині (Windows 11)

Стан на 2026-09-05:

| Що | Стан |
|----|------|
| Flutter SDK | **Є**: `E:\flutter` (3.47.2 stable, Dart уже завантажено, `flutter --version` працює). У PATH **не** доданий |
| Android SDK | **Немає** |
| Java | **Є**: Microsoft OpenJDK 17.0.14 у PATH (підходить для AGP 8.x). `JAVA_HOME` визначити: `(Get-Command java).Source` |
| Git | 2.45.2 |
| Диск | C: 10 ГБ вільно (мало), E: 21 ГБ вільно. **Усе важке ставимо на E:** |
| Пристрій | Android-телефон власника, підключення по USB або встановлення APK вручну |

Налаштування сесії PowerShell (агент виконує на початку кожної сесії):

```powershell
$env:Path = "E:\flutter\bin;$env:Path"
$env:ANDROID_HOME = "E:\Android\Sdk"
$env:GRADLE_USER_HOME = "E:\gradle"      # кеш Gradle 1-2 ГБ не на C:
flutter doctor -v
```

Встановлення Android SDK (частина M0):

1. Агент: завантажити `commandlinetools-win-*_latest.zip` зі сторінки https://developer.android.com/studio#command-line-tools-only, розпакувати так, щоб вийшло `E:\Android\Sdk\cmdline-tools\latest\bin\sdkmanager.bat`.
2. **[ЛЮДИНА]** прийняти ліцензії Google: `E:\Android\Sdk\cmdline-tools\latest\bin\sdkmanager.bat --licenses` (відповідати `y`).
3. Агент: `sdkmanager.bat "platform-tools" "platforms;android-35" "build-tools;35.0.0"`, потім `flutter config --android-sdk E:\Android\Sdk`, `flutter doctor -v` без червоних пунктів у розділі Android toolchain.
4. NDK **не потрібен** (рідного коду не компілюємо). Попередження Gradle «Unable to strip the following libraries» при release-збірці допустиме.

Що потрібно від власника до етапу M1 **[ЛЮДИНА]**:

| Дані | Де взяти | Куди вводити |
|------|----------|--------------|
| `api_id`, `api_hash` | https://my.telegram.org → API development tools → створити застосунок (будь-яка назва, платформа Android) | Екран «Налаштування» застосунку |
| Bot token | @BotFather → `/newbot` | Екран «Налаштування» |
| Цільовий канал | Створити приватний канал «Тривога біля дому», додати бота адміністратором із правом «Публікувати повідомлення» | Екран «Налаштування»: `@username` публічного або числовий id `-100…` приватного каналу. Як дізнатися id приватного: переслати будь-який пост каналу боту @getidsbot або @userinfobot |
| Тестовий канал | Приватний канал, де власник сам постить тестові повідомлення; додати його в моніторингову папку | Для ручних тестів T5–T12 |

---

## 6. Функціональні вимоги

### 6.1 Екран «Налаштування»

Поля (усі зберігаються в SharedPreferences):

| Поле | Ключ | Валідація |
|------|------|-----------|
| api_id | `apiId` | ціле > 0 |
| api_hash | `apiHash` | 32 hex-символи |
| Токен бота | `botToken` | формат `^\d+:[A-Za-z0-9_-]{30,}$`; поле з маскуванням |
| Цільовий чат | `targetChatId` | `@username` або ціле (зазвичай `-100…`) |
| Макс. вік повідомлення, хв | `maxAgeMinutes` | 1–120, за замовчуванням 10 |

Кнопки:

- **«Перевірити бота»**: викликає Bot API `getMe` і `getChat(targetChatId)`; показує ім'я бота і назву каналу або зрозумілу помилку (невірний токен / бот не в каналі / чат не знайдено).
- **«Надіслати тестове повідомлення»**: `sendMessage` у цільовий канал тексту `✅ TG Alert Monitor: тест, <дата-час>`.

Зміна `apiId`/`apiHash` після логіну вимагає виходу з акаунта (кнопка «Вийти» на екрані логіну), бо параметри TDLib задаються один раз на БД.

### 6.2 Екран «Логін»

Кроки за станами TDLib:

1. `authorizationStateWaitPhoneNumber` → поле «Номер телефону» у міжнародному форматі, кнопка «Далі».
2. `authorizationStateWaitCode` → поле «Код», підказка, куди прийшов код (з `code_info.type`: у Telegram на іншому пристрої / SMS / дзвінок), кнопка «Надіслати код повторно» (`resendAuthenticationCode`).
3. `authorizationStateWaitPassword` → поле «Пароль двофакторної автентифікації», показати `password_hint`.
4. `authorizationStateReady` → перехід на головний екран; показати ім'я з `getMe`.

Нештатні стани: `authorizationStateWaitRegistration` (акаунта не існує), `WaitEmailAddress`/`WaitEmailCode`, `WaitPremiumPurchase`, `WaitOtherDeviceConfirmation` → показати текст «Цей сценарій входу не підтримується, увійдіть у офіційний Telegram і спробуйте ще раз». Помилки TDLib (`PHONE_CODE_INVALID`, `PASSWORD_HASH_INVALID`, `FLOOD_WAIT_N`) показувати людською мовою, дозволяти повторити.

Кнопка «Вийти» (`logOut`) з підтвердженням: зупиняє моніторинг, чистить сесію, повертає на крок 1.

Після перезапуску застосунку логін повторно не потрібен (сесія у БД TDLib).

### 6.3 Головний екран

Блоки зверху вниз:

1. **Статус**: підключення (`онлайн` / `підключення…` / `немає мережі`), стан моніторингу (`зупинено` / `активний з HH:mm`), кількість чатів у папці, кількість збігів за сесію, час останнього збігу.
2. **Папка**: випадаючий список папок Telegram (з `updateChatFolders`, назва з `name.text.text`). Під ним: «N чатів» і кнопка «Показати чати» (список назв; канали позначені іконкою). Пункт «Усі чати» (`chatListMain`) не обов'язковий (M5).
3. **Ключові слова**: чипи зі списком, поле додавання (Enter або кнопка), видалення хрестиком. Зберігаються як `keywords` (List<String>). Порожні і дублікати (без урахування регістру) не додаються.
4. **Кнопка «Старт» / «Стоп»**. «Старт» недоступна, якщо: не залогінені, папка не вибрана, немає ключових слів, не заповнені токен бота і цільовий чат, не надано дозвіл на сповіщення.
5. **Дозволи**: якщо не надані, картки з кнопками «Дозволити сповіщення» (`requestNotificationPermission`) і «Вимкнути оптимізацію батареї» (`requestIgnoreBatteryOptimization`) з поясненням, чому це потрібно. Для Xiaomi/Huawei/Samsung показати підказку про «Автозапуск»/«Не обмежувати» в системних налаштуваннях.

Стан «моніторинг активний» зберігається як `monitoringActive=true`; сервіс сам відновлює моніторинг після перезавантаження телефону або перезапуску процесу без участі UI.

### 6.4 Екран «Журнал»

Останні 500 збігів з `matches.jsonl` (новіші зверху): час, назва чату, ключові слова, перші 200 символів тексту, статус доставки (✅ надіслано / ⏳ у черзі / ❌ помилка з текстом). Тап по запису відкриває оригінал у Telegram за посиланням (`url_launcher` не обов'язковий: можна показати посилання для копіювання). Кнопка «Очистити».

Окремо вкладка «Системний журнал»: останні 300 рядків подій сервісу (`log`-події: підключення, реконнекти, помилки Bot API, перезавантаження папки). Без секретів.

### 6.5 Сповіщення foreground-сервісу

Постійне сповіщення з низьким пріоритетом (без звуку): заголовок `TG Alert Monitor`, текст оновлюється: `Моніторинг • 12 чатів • 3 збіги • онлайн` або `Підключено, моніторинг зупинено`. Тап відкриває застосунок. Кнопка в сповіщенні «Стоп» (необов'язково, M4).

---

## 7. Технічна специфікація

### 7.1 Структура проєкту

```
lib/
  main.dart                      initCommunicationPort, init foreground task, runApp
  app.dart                       MaterialApp, тема, маршрути
  core/
    td/td_native.dart            FFI-типи і lookup символів libtdjson
    td/td_transport.dart         receive-ізолят + send; інтерфейс TdTransport
    td/td_client.dart            TdClient: send(Map) -> Future<Map> (кореляція за @extra), Stream<Map> updates
    td/td_json.dart              extractText(content), folderName(info), fallbackLink(chatId, msgId)
    matcher/keyword_matcher.dart
    bot/bot_api.dart             BotApi(http.Client, token): sendMessage, getMe, getChat
    bot/message_formatter.dart   формування HTML-тексту, екранування, обрізання
    bot/forward_queue.dart       черга з інтервалом, повторами, обробкою 429
    model/app_config.dart        MonitorConfig (+ toJson/fromJson)
    model/match_entry.dart
    ipc/protocol.dart            команди/події UI<->сервіс, серіалізація
    storage/settings_store.dart  SharedPreferences-обгортка
    storage/match_log.dart       matches.jsonl append/read/rotate
    util/app_logger.dart         буфер логів + маскування секретів
  service/
    monitor_task_handler.dart    TaskHandler (flutter_foreground_task), клей до MonitorEngine
    monitor_engine.dart          оркестрація: AuthFlow, FolderResolver, MessagePipeline (без Flutter-залежностей)
  ui/
    service_bridge.dart          sendDataToTask/addTaskDataCallback -> Stream подій, ChangeNotifier стану
    screens/settings_screen.dart
    screens/login_screen.dart
    screens/home_screen.dart
    screens/log_screen.dart
android/app/src/main/jniLibs/{arm64-v8a,armeabi-v7a,x86_64}/libtdjson.so
test/                            див. розділ 9
```

`MonitorEngine` і все в `core/` не імпортують `package:flutter` (крім `foundation` за потреби) і тестуються звичайними Dart-тестами.

### 7.2 FFI-обгортка TDLib (`td_native.dart`)

Використовуємо сучасний API (`td_json_client.h`):

```c
int         td_create_client_id();
void        td_send(int client_id, const char *request);
const char *td_receive(double timeout);        // глобальний для всіх клієнтів; блокує
const char *td_execute(const char *request);   // синхронно, лише для setLogVerbosityLevel/setLogStream тощо
```

Dart-типи:

```dart
typedef _CreateClientIdC = ffi.Int32 Function();
typedef _SendC    = ffi.Void Function(ffi.Int32, ffi.Pointer<Utf8>);
typedef _ReceiveC = ffi.Pointer<Utf8> Function(ffi.Double);
typedef _ExecuteC = ffi.Pointer<Utf8> Function(ffi.Pointer<Utf8>);
// DynamicLibrary.open('libtdjson.so'); lookup 'td_create_client_id', 'td_send', 'td_receive', 'td_execute'
```

Правила:

- `td_receive` викликається **тільки** в окремому ізоляті (`Isolate.spawn`) у циклі з `timeout = 1.0`; рядок результату відправляється через `SendPort`. Рядки, повернуті `td_receive`/`td_execute`, належать TDLib, їх **не** звільняємо. Рядки, передані в `td_send`/`td_execute`, виділяємо через `toNativeUtf8()` і звільняємо `malloc.free` після виклику.
- Один receive-цикл на процес (бо `td_receive` глобальний). У процесі один клієнт.
- Перед створенням клієнта: `td_execute({"@type":"setLogVerbosityLevel","new_verbosity_level":2})` і `setLogStream` → `logStreamFile` у `<support>/tdlib/td.log`, `max_file_size` 5 МБ, `redirect_stderr: false`.

### 7.3 `TdClient`

- `Future<Map<String,dynamic>> send(Map<String,dynamic> request, {Duration timeout = 30s})`: додає `@extra` (монотонний лічильник як рядок), чекає відповідь з тим самим `@extra`. Якщо відповідь має `@type == "error"` → кидає `TdError(code, message)`. Таймаут → `TdTimeout`.
- `Stream<Map<String,dynamic>> get updates`: усі повідомлення без `@extra` (оновлення).
- Конструктор приймає абстрактний `TdTransport { void send(String json); Stream<String> incoming; }`. Реальна реалізація `IsolateTdTransport` (receive-ізолят), у тестах `FakeTdTransport`.
- Після `authorizationStateClosed` клієнт вважається мертвим: новий `td_create_client_id` при наступному старті.

### 7.4 Параметри TDLib

`setTdlibParameters` (надсилається у відповідь на `authorizationStateWaitTdlibParameters`):

```json
{
  "@type": "setTdlibParameters",
  "use_test_dc": false,
  "database_directory": "<getApplicationSupportDirectory()>/tdlib/db",
  "files_directory": "<getApplicationSupportDirectory()>/tdlib/files",
  "database_encryption_key": "",
  "use_file_database": false,
  "use_chat_info_database": true,
  "use_message_database": true,
  "use_secret_chats": false,
  "api_id": <apiId>,
  "api_hash": "<apiHash>",
  "system_language_code": "uk",
  "device_model": "TG Alert Monitor",
  "system_version": "Android <release>",
  "application_version": "<версія з pubspec>"
}
```

`use_file_database=false`: медіа не завантажуємо. `use_message_database=true`: після реконнекту/перезапуску TDLib сам підтягує пропущені повідомлення каналів і видає їх як `updateNewMessage` (звідси потреба у фільтрі `maxAge` і дедуплікації).

### 7.5 Автентифікація (`AuthFlow`)

Автомат на `updateAuthorizationState.authorization_state["@type"]`:

| Стан | Дія сервісу | Подія в UI |
|------|-------------|------------|
| `authorizationStateWaitTdlibParameters` | `setTdlibParameters` | `state.auth = "init"` |
| `authorizationStateWaitPhoneNumber` | чекає команду `auth.phone` → `setAuthenticationPhoneNumber {phone_number}` | `waitPhone` |
| `authorizationStateWaitCode` | чекає `auth.code` → `checkAuthenticationCode {code}` | `waitCode` + `codeType` |
| `authorizationStateWaitPassword` | чекає `auth.password` → `checkAuthenticationPassword {password}` | `waitPassword` + `hint` |
| `authorizationStateReady` | `getMe`; `loadChats(chatListMain, 100)` до помилки 404 (щоб TDLib знав усі чати і отримував оновлення каналів); якщо `monitoringActive` → запуск моніторингу | `ready` + `userName` |
| `authorizationStateLoggingOut` / `Closing` | нічого | `closing` |
| `authorizationStateClosed` | клієнт мертвий; якщо це не був явний `logOut`/`close` → створити новий клієнт | `closed` |
| інші (`WaitRegistration`, `WaitEmail*`, `WaitPremiumPurchase`, `WaitOtherDeviceConfirmation`) | нічого | `unsupported` + назва стану |

Помилки від `checkAuthenticationCode`/`checkAuthenticationPassword` пересилаються в UI подією `error` з `code` і `message`.

### 7.6 Папки (`FolderResolver`)

- Список папок: з `updateChatFolders.chat_folders[]` (`chatFolderInfo`: `id:int32`, `name.text.text:string`). Зберігати останній список у пам'яті сервісу; UI отримує його по команді `folders.list` і при кожному оновленні.
- Чати папки `F`:
  1. `loadChats {"chat_list": {"@type":"chatListFolder","chat_folder_id":F}, "limit":100}` повторювати, поки не прийде `error` з `code == 404` (усе завантажено).
  2. `getChats {"chat_list": {...}, "limit": 1000}` → `chats.chat_ids[]`.
  3. Для кожного id: `getChat` → `title`, `type` (`chatTypeSupergroup.is_channel` для позначки «канал»).
- Результат кешується в `MonitorConfig.chats` (id + title) і в SharedPreferences, щоб після перезавантаження моніторинг стартував одразу, а перерахунок папки відбувся у фоні.
- Перерахунок папки: при старті моніторингу, далі кожні 30 хв у `onRepeatEvent`, а також при `updateChatPosition`, де `position.list` це наша папка (додавання/видалення чату з папки в Telegram).

### 7.7 Обробка повідомлень (`MessagePipeline`)

Вхід: `updateNewMessage.message`. Відкидаємо, якщо будь-що з:

1. `message.chat_id` не в множині чатів папки.
2. `message.is_outgoing == true`.
3. `extractText(message.content)` порожній. `extractText`:
   - `messageText` → `text.text`
   - `messagePhoto`, `messageVideo`, `messageDocument`, `messageAnimation` → `caption.text`
   - решта типів → `null`
4. `now - message.date > maxAgeMinutes*60` (захист від лавини старих повідомлень після реконнекту).
5. `(chat_id, message.id)` вже є в LRU-множині останніх 2000 оброблених.

Далі `KeywordMatcher.match(text)`; при збігу:

- сформувати `MatchEntry {time, chatId, chatTitle, messageId, text, keywords, link, status}`;
- посилання: `getMessageLink {"chat_id", "message_id", "media_timestamp":0, "checklist_task_id":0, "poll_option_id":"", "for_album":false, "in_message_thread":false}` → `messageLink.link`. При помилці fallback: для `chat_id` виду `-100XXXXXXXXXX` → `https://t.me/c/XXXXXXXXXX/<message_id>`;
- записати у `matches.jsonl`, надіслати подію `match` в UI, поставити в `ForwardQueue`.

`updateMessageContent` (редагування) **не** обробляємо: уникнення дублікатів важливіше.

### 7.8 `KeywordMatcher`

- Нормалізація і слів, і тексту: `trim`, `toLowerCase()` (Dart коректно працює з кирилицею), послідовності пробільних символів → один пробіл, видалення zero-width символів (`\u200B`-`\u200D`, `\uFEFF`).
- Порожні ключові слова ігноруються.
- Збіг: хоча б одне слово є підрядком тексту. Повертає список усіх збіглих слів у порядку списку.
- Необов'язково (M5): слово з префіксом `-` є винятком: якщо будь-який виняток є в тексті, збігу немає (напр. `-відбій`).

### 7.9 Відправка через Bot API (`BotApi`, `MessageFormatter`, `ForwardQueue`)

`POST https://api.telegram.org/bot<token>/sendMessage`, JSON:

```json
{"chat_id": "<targetChatId>", "text": "<html>", "parse_mode": "HTML",
 "link_preview_options": {"is_disabled": true}}
```

Формат тексту (HTML; `<`, `>`, `&` у користувацьких даних екрануються **обов'язково**):

```
🔔 <b>{назва чату}</b>
🔑 {ключові слова через кому}

{текст повідомлення, обрізаний до 3500 символів з «…»}

<a href="{link}">Відкрити оригінал</a> · {HH:mm}
```

Загальна довжина після обрізання ≤ 4096 символів (ліміт Bot API).

`ForwardQueue`:

- FIFO, один воркер, мінімальний інтервал між відправками 1500 мс (ліміт Telegram ≈20 повідомлень/хв у один канал).
- HTTP 429 → чекати `parameters.retry_after` секунд і повторити.
- 5xx / мережева помилка / таймаут (15 с) → експоненційна затримка 2, 4, 8 … 60 с, до 10 спроб, потім статус `failed` з текстом помилки.
- 400/401/403 (невірний токен, бот не адмін, чат не знайдено) → без повторів, статус `failed`, подія `error` в UI.
- Статус кожного запису оновлюється в `matches.jsonl` (`queued` → `sent` / `failed`) і подією `matchStatus`.

### 7.10 Foreground-сервіс (`flutter_foreground_task` 11.x)

`main.dart`:

```dart
void main() {
  FlutterForegroundTask.initCommunicationPort();
  runApp(const App());
}
```

Ініціалізація (один раз до `startService`):

```dart
FlutterForegroundTask.init(
  androidNotificationOptions: AndroidNotificationOptions(
    channelId: 'tg_alert_monitor',
    channelName: 'Моніторинг Telegram',
    channelImportance: NotificationChannelImportance.LOW,
    priority: NotificationPriority.LOW,
  ),
  iosNotificationOptions: const IOSNotificationOptions(),
  foregroundTaskOptions: ForegroundTaskOptions(
    eventAction: ForegroundTaskEventAction.repeat(60000),
    autoRunOnBoot: true,
    autoRunOnMyPackageReplaced: true,
    allowWakeLock: true,
    allowWifiLock: true,
  ),
);
```

Точка входу сервісу:

```dart
@pragma('vm:entry-point')
void startCallback() {
  FlutterForegroundTask.setTaskHandler(MonitorTaskHandler());
}
```

`MonitorTaskHandler`:

- `onStart(timestamp, starter)`: прочитати конфіг із SharedPreferences (`reload()` обов'язково, бо інший ізолят); створити `TdClient`; якщо `monitoringActive` → одразу `engine.startMonitoring(config)`. `starter == TaskStarter.boot` лише логуємо.
- `onRepeatEvent` (раз на хвилину): watchdog. Якщо `connectionState` не `ready` довше 2 хв → `setNetworkType {"type":{"@type":"networkTypeOther"}}` (підштовхує реконнект). Оновити текст сповіщення (`FlutterForegroundTask.updateService`). Кожні 30 хв → перерахунок папки. Якщо моніторинг не активний і UI надіслав `ui.detached` понад 60 с тому → `close` TDLib і `FlutterForegroundTask.stopService()`.
- `onReceiveData(data)`: `data` це JSON-рядок команди (розділ 7.11).
- `onDestroy(timestamp, isTimeout)`: `close` TDLib, дочекатися `authorizationStateClosed` (до 5 с), вбити receive-ізолят.
- `onNotificationPressed`: `FlutterForegroundTask.launchApp()`.

Сигнатури методів `TaskHandler` звірити з README пакета версії, що встановиться (`onStart(DateTime, TaskStarter)`, `onRepeatEvent(DateTime)`, `onDestroy(DateTime, bool)`, `onReceiveData(Object)`).

`AndroidManifest.xml`:

```xml
<uses-permission android:name="android.permission.INTERNET"/>
<uses-permission android:name="android.permission.FOREGROUND_SERVICE"/>
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_SPECIAL_USE"/>
<uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>
<uses-permission android:name="android.permission.RECEIVE_BOOT_COMPLETED"/>
<uses-permission android:name="android.permission.WAKE_LOCK"/>
<uses-permission android:name="android.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS"/>

<application ...>
  <service
      android:name="com.pravera.flutter_foreground_task.service.ForegroundService"
      android:foregroundServiceType="specialUse"
      android:exported="false">
    <property
        android:name="android.app.PROPERTY_SPECIAL_USE_FGS_SUBTYPE"
        android:value="Keeps a persistent Telegram connection to relay air-raid alerts"/>
  </service>
</application>
```

Якщо README пакета вимагає інший спосіб вказати тип сервісу, слідувати README і записати відхилення.

Плагіни через platform channels (`shared_preferences`, `path_provider`) працюють в ізоляті сервісу (реєструються автоматично). Перевірити на M0; якщо ні, у сервісі писати/читати файл конфігу напряму через `dart:io`.

### 7.11 Протокол UI ↔ сервіс

Транспорт: `FlutterForegroundTask.sendDataToTask(String json)` і `FlutterForegroundTask.sendDataToMain(String json)`. Завжди рядок JSON.

Команди (UI → сервіс), поле `cmd`:

| `cmd` | Поля | Дія |
|-------|------|-----|
| `ui.attached` | | UI відкрито; сервіс відповідає повним `state` |
| `ui.detached` | | UI закрито; таймер самозупинки, якщо моніторинг не активний |
| `auth.phone` | `phone` | `setAuthenticationPhoneNumber` |
| `auth.code` | `code` | `checkAuthenticationCode` |
| `auth.resend` | | `resendAuthenticationCode {"reason":{"@type":"resendCodeReasonUserRequest"}}` |
| `auth.password` | `password` | `checkAuthenticationPassword` |
| `auth.logout` | | зупинити моніторинг, `logOut` |
| `folders.list` | | подія `folders` |
| `folders.chats` | `folderId` | резолв папки, подія `folderChats` |
| `monitor.start` | `config` (MonitorConfig JSON) | зберегти конфіг, `monitoringActive=true`, старт |
| `monitor.stop` | | `monitoringActive=false`, стоп |
| `bot.check` | `botToken`, `targetChatId` | `getMe` + `getChat`, подія `botInfo` або `error` |
| `bot.test` | `botToken`, `targetChatId` | тестове повідомлення |
| `log.get` | | подія `logLines` з буфером системного журналу |

Події (сервіс → UI), поле `ev`:

| `ev` | Поля |
|------|------|
| `state` | `auth` (init/waitPhone/waitCode/waitPassword/ready/closing/closed/unsupported), `authDetail` (codeType/hint/назва стану), `userName`, `connection` (ready/connecting/updating/waitingForNetwork), `monitoring` (bool), `startedAt`, `chatCount`, `matchCount`, `lastMatchAt`, `tdVersion` |
| `folders` | `items: [{id, name}]` |
| `folderChats` | `folderId`, `items: [{id, title, isChannel}]` |
| `match` | `MatchEntry` JSON |
| `matchStatus` | `chatId`, `messageId`, `status` (queued/sent/failed), `error` |
| `botInfo` | `botName`, `chatTitle` |
| `error` | `scope` (auth/bot/td/folder), `code`, `message` |
| `log` | `time`, `level`, `message` |
| `logLines` | `lines: [...]` |

`MonitorConfig`: `{folderId, folderName, keywords[], botToken, targetChatId, maxAgeMinutes, chats:[{id,title}]}`.

### 7.12 Зберігання

- SharedPreferences: `apiId`, `apiHash`, `botToken`, `targetChatId`, `maxAgeMinutes`, `folderId`, `folderName`, `keywords`, `monitoringActive`, `cachedChats` (JSON), `phoneDisplay` (для показу, без коду).
- `<support>/tdlib/` — БД і файли TDLib. `<support>/td.log` — лог TDLib (5 МБ ротація).
- `<support>/matches.jsonl` — один JSON на рядок; при >1000 рядків залишати останні 500.
- Секрети в app-private storage без шифрування (особистий пристрій). Необов'язково (M5): `database_encryption_key` випадковий 32 байти у `flutter_secure_storage`.

### 7.13 Логування

`AppLogger` у сервісі: кільцевий буфер 300 рядків + `debugPrint`. Перед записом рядок проходить маскування: значення `botToken`, `apiHash`, будь-яка підстрока виду `\d+:[A-Za-z0-9_-]{30,}` замінюються на `***`. Тексти повідомлень у системний журнал не пишуться (лише id).

### 7.14 Стійкість

- Реконнект робить сам TDLib; ми лише показуємо `updateConnectionState` і підштовхуємо через `setNetworkType` при довгому `waitingForNetwork`.
- Якщо receive-ізолят помер (помилка) → лог, перезапуск клієнта з нуля (новий `td_create_client_id`), моніторинг відновлюється автоматично, бо `monitoringActive` збережено.
- Після перезавантаження телефону `autoRunOnBoot` піднімає сервіс; сервіс читає конфіг і стартує моніторинг без UI.
- `maxAge` і LRU-дедуплікація захищають цільовий канал від лавини після довгого офлайну.
- `ForwardQueue` живе в пам'яті; при загибелі процесу невідправлене втрачається, але записи в `matches.jsonl` зі статусом `queued` видно в журналі.

---

## 8. Нефункціональні вимоги

- Час від публікації в каналі до появи в цільовому каналі: ≤ 10 с при онлайні (орієнтир; залежить від Telegram).
- Споживання батареї за 8 годин моніторингу на Wi-Fi: орієнтир ≤ 5 % (TDLib тримає одне з'єднання, як офіційний клієнт).
- APK (`arm64-v8a`) ≤ 40 МБ.
- `flutter analyze` без попереджень; `dart format` без змін.

---

## 9. Тестування

### 9.1 Юніт-тести (`flutter test`), обов'язкові

| Файл | Що перевіряє |
|------|--------------|
| `test/keyword_matcher_test.dart` | регістр і кирилиця (`Шахед` ↔ `ШАХЕДИ`); кілька слів, порядок результату; порожній список → без збігу; пробільні слова ігноруються; слово з пробілом (`балістика на`) проти тексту з переносами; zero-width символи; емодзі в тексті; (M5) винятки з `-` |
| `test/td_json_test.dart` | `extractText` для `messageText`, `messagePhoto`/`Video`/`Document`/`Animation` з підписом, без підпису → null, `messageSticker` → null, неповний JSON не кидає; `folderName`; `fallbackLink(-1001234567890, 55) == https://t.me/c/1234567890/55` |
| `test/message_formatter_test.dart` | екранування `<b>&`, обрізання до ліміту з `…`, підсумкова довжина ≤ 4096, наявність посилання і ключових слів |
| `test/td_client_test.dart` | з `FakeTdTransport`: відповідь зіставляється за `@extra`; оновлення без `@extra` йдуть у `updates`; `@type: error` → `TdError`; таймаут → `TdTimeout`; паралельні запити не плутаються |
| `test/monitor_engine_test.dart` | з `FakeTdTransport` + `FakeBotApi` + керованим годинником: (a) послідовність auth-станів породжує правильні запити і події; (b) резолв папки: `loadChats` до 404, `getChats`, `getChat`; (c) pipeline: збіг у чаті папки → один виклик `sendMessage` з правильним текстом; чат поза папкою, `is_outgoing`, старе повідомлення, дублікат, повідомлення без тексту → 0 викликів; підпис до фото → збіг; (d) `monitor.stop` → нові повідомлення ігноруються; (e) `updateChatPosition` для папки → перерахунок |
| `test/forward_queue_test.dart` | з `MockClient`: інтервал між відправками ≥ 1500 мс (fake async); 429 з `retry_after` → повтор після паузи; 500 → повтори з ростом затримки і зрештою `failed`; 403 → одразу `failed` без повторів; статуси оновлюються |
| `test/protocol_test.dart` | усі команди/події round-trip через JSON; невідомий `cmd` → помилка без падіння |
| `test/settings_store_test.dart` | з `SharedPreferences.setMockInitialValues`: збереження/читання конфігу, дедуплікація ключових слів |

Фейки (`test/fakes/`): `FakeTdTransport` (черга вхідних рядків, список надісланих запитів, автовідповіді за `@type`), `FakeBotApi`, `FakeClock`. Використовувати `package:fake_async` для таймерів.

### 9.2 Статичні перевірки

```powershell
flutter analyze
dart format --set-exit-if-changed lib test
flutter test
```

### 9.3 Збірка

```powershell
flutter build apk --release --split-per-abi
```

Перевірити, що в `build/app/outputs/flutter-apk/app-arm64-v8a-release.apk` є `lib/arm64-v8a/libtdjson.so` (розпакувати як zip). Release підписується debug-ключем із шаблону Flutter (достатньо для sideload; ключ `~/.android/debug.keystore` стабільний на цій машині, тож оновлення ставляться поверх).

Перевірка вирівнювання під 16 КБ сторінки (нові пристрої на Android 15+): для `libtdjson.so` `LOAD`-сегменти мають align `0x4000`. Перевірити через `llvm-readelf -l` (є в NDK/LLVM) або скриптом на Python (`pyelftools`). Якщо вирівнювання `0x1000`, а телефон власника з 16 КБ сторінками, додати в `<application>` `android:pageSizeCompat="enabled"` (Android 16) і зафіксувати ризик у розділі 11.

### 9.4 Ручні тести на телефоні **[ЛЮДИНА]**

Передумови: тестовий приватний канал `Test alerts` у моніторинговій папці; цільовий канал з ботом-адміном; ключові слова `шахед`, `тест-ключ`.

| # | Кроки | Очікування |
|---|-------|------------|
| T1 | Перший запуск; заповнити налаштування; «Перевірити бота»; закрити і відкрити застосунок | Запити дозволів на сповіщення і батарею показані; бот і канал розпізнані; налаштування збережені |
| T2 | Логін: телефон → код → (пароль 2FA) | Стан `ready`, ім'я користувача показане; після перезапуску застосунку логін не потрібен |
| T3 | Вибрати папку, «Показати чати» | Список папок як у Telegram; чати папки збігаються з Telegram, канали позначені |
| T4 | Додати ключові слова, «Старт» | Сповіщення сервісу з'явилося; статус `онлайн`, `моніторинг активний` |
| T5 | У `Test alerts` опублікувати `тест-ключ 1`, потім `просто текст`, потім фото з підписом `Шахед над містом` | Перше і третє через ≤10 с з'являються в цільовому каналі у правильному форматі, посилання «Відкрити оригінал» веде на пост; друге не пересилається; журнал показує 2 записи зі статусом ✅ |
| T6 | Згорнути застосунок, змахнути з «Останніх», вимкнути екран на 15 хв, опублікувати `тест-ключ 2` | Пересилається без відкриття застосунку |
| T7 | Увімкнути авіарежим на 3 хв; за цей час з іншого пристрою опублікувати `тест-ключ 3`; вимкнути авіарежим | Статус проходить `немає мережі` → `онлайн`; повідомлення пересилається один раз |
| T8 | Перезавантажити телефон, не відкривати застосунок, опублікувати `тест-ключ 4` | Сповіщення сервісу повертається саме; повідомлення пересилається |
| T9 | «Стоп»; опублікувати `тест-ключ 5` | Сповіщення зникає; нічого не пересилається; після повторного «Старт» пересилання відновлюється |
| T10 | У налаштуваннях зіпсувати токен; «Перевірити бота». Прибрати бота з адмінів каналу; «Надіслати тестове» | Зрозумілі помилки в UI та системному журналі; без падінь |
| T11 | Відредагувати вже переслане повідомлення в `Test alerts` | Повторного пересилання немає |
| T12 | Опублікувати 20 повідомлень з `тест-ключ` за 30 с | Усі 20 доставлені (з паузами), жодного `failed`, порядок збережено |
| T13 | Переглянути системний журнал і `td.log` | Токенів, api_hash, кодів немає |
| T14 | Залишити моніторинг на ніч | Вранці статус `онлайн`, споживання батареї в системних налаштуваннях у межах орієнтира |

### 9.5 Критерії приймання

- 9.1 і 9.2 зелені, 9.3 збирається.
- T1–T13 пройдені на реальному телефоні власника (записати модель і версію Android у розділ 13).
- T14 як інформаційний.

---

## 10. План робіт

Кожен етап завершується комітом (Conventional Commits, напр. `feat(td): request/response correlation`) і зеленими перевірками 9.2.

### M0. Середовище і скелет

1. Android SDK за розділом 5 (крок 2 робить **[ЛЮДИНА]**).
2. `flutter create --project-name tg_alert_monitor --org com.vadimart --platforms android .` у цій папці; `minSdk 26`.
3. Залежності з розділу 4; `.gitignore` за шаблоном Flutter + `*.keystore`, `*.jks`, `.env*`.
4. Завантажити `jniLibs.tar.gz` v1.8.65 з релізів up9cloud, покласти `libtdjson.so` у `android/app/src/main/jniLibs/<abi>/` для `arm64-v8a`, `armeabi-v7a`, `x86_64`. Записати SHA-256 архіву в README. У Gradle `ndk { abiFilters += listOf("arm64-v8a","armeabi-v7a","x86_64") }`.
5. Манифест і `init` за 7.10; порожній `MonitorTaskHandler`, який раз на хвилину шле в UI `log`. Головний екран показує ці рядки.
6. `td_native.dart`: відкрити бібліотеку в ізоляті сервісу і синхронно викликати `td_execute({"@type":"getOption","name":"version"})` (`getOption` дозволено викликати синхронно для `version` і `commit_hash`). Очікувана відповідь `{"@type":"optionValueString","value":"1.8.65"}`; значення писати в лог і в поле `tdVersion` події `state`.

DoD: `flutter build apk --debug` успішна; на телефоні застосунок запускається, сповіщення сервісу видно, у UI приходять хвилинні `log`-рядки, серед них `tdlib 1.8.65`.

### M1. TDLib і логін

1. `TdTransport` з receive-ізолятом, `TdClient`, `AuthFlow`, `ServiceBridge`, екран логіну, екран налаштувань (api_id/api_hash обов'язкові для цього етапу).
2. Тести: `td_client_test`, `protocol_test`, `settings_store_test`, частина (a) `monitor_engine_test`.

DoD: T2 проходить; у `state` є `tdVersion == "1.8.65"`; після перезапуску застосунку стан `ready` без повторного логіну.

### M2. Папки, ключові слова, конфіг

1. `FolderResolver`, події `folders`/`folderChats`, головний екран без кнопки «Старт» (папка, чати, ключові слова, статус підключення).
2. `KeywordMatcher`, `td_json.dart`, тести `keyword_matcher_test`, `td_json_test`, частина (b) `monitor_engine_test`.

DoD: T3 проходить; ключові слова і папка переживають перезапуск.

### M3. Пайплайн і Bot API

1. `MessagePipeline`, `BotApi`, `MessageFormatter`, `ForwardQueue`, `MatchLog`, кнопки «Старт»/«Стоп», «Перевірити бота», «Тестове повідомлення», екран журналу.
2. Тести `message_formatter_test`, `forward_queue_test`, частини (c)(d) `monitor_engine_test`.

DoD: T4, T5, T9, T10, T11 проходять.

### M4. Стійкість і фон

1. `monitoringActive` + автозапуск після boot, watchdog в `onRepeatEvent`, оновлення тексту сповіщення, `setNetworkType`, перерахунок папки за розкладом і за `updateChatPosition`, маскування логів, картки дозволів, підказки для OEM.
2. Тест (e) `monitor_engine_test`; перевірка 16 КБ вирівнювання; `README.md` з інструкцією для власника (ключі, бот, канал, дозволи, встановлення APK).

DoD: T1, T6, T7, T8, T12, T13 проходять; release-APK зібраний і встановлений.

### M5. Необов'язково (після приймання)

- Локальне гучне сповіщення на телефоні при збігу (окремий канал сповіщень з високим пріоритетом, звук тривоги).
- Винятки `-слово`.
- Пункт «Усі чати» (`chatListMain`).
- Кнопка «Знайти id каналу» через Bot API `getUpdates` (`channel_post.chat.id`).
- `database_encryption_key` у `flutter_secure_storage`.
- Кнопка «Стоп» у сповіщенні.

---

## 11. Ризики і пом'якшення

| Ризик | Пом'якшення |
|-------|-------------|
| Довіра до сторонніх бінарників TDLib (up9cloud) | Зафіксувати SHA-256; альтернатива для параноїдального режиму: власна збірка TDLib з NDK (окремий етап, поза MVP) |
| 16 КБ сторінки пам'яті на нових телефонах | Перевірка вирівнювання в M4; `pageSizeCompat`; у крайньому разі власна збірка |
| Android 15+ і ліміти foreground-сервісів | Тип `specialUse` (R5). Якщо система все одно вбиває сервіс, увімкнути «без обмежень» для батареї (картка в UI) |
| OEM-прошивки (Xiaomi, Huawei, Samsung) вбивають фонові сервіси | Підказки в UI: автозапуск, батарея без обмежень, закріпити застосунок у «Останніх» |
| Telegram обмежує нові сесії (`FLOOD_WAIT`, код приходить в інший клієнт) | Показувати `codeType` і таймер повтору; не спамити спробами |
| Лавина повідомлень після довгого офлайну | `maxAge` + LRU + інтервал черги |
| Ліміти Bot API (20/хв у канал) | Черга з інтервалом 1.5 с, обробка 429 |
| Зміни назв полів у майбутніх версіях TDLib | Версія зафіксована (1.8.65); при оновленні звіряти з `td_api.tl` |
| Хибні спрацювання (`шахед` у «збили шахед») | Налаштування слів власником; винятки в M5 |

---

## 12. Поза межами (non-goals)

iOS і десктоп; кілька акаунтів; пересилання медіа; regex; справжній forward; історія повідомлень до старту; веб-панель; публікація в Play.

---

## 13. Журнал відхилень і фактів з пристрою

(заповнюють агенти під час реалізації)

| Дата | Розділ | Що змінено і чому |
|------|--------|-------------------|
| 2026-09-05 | 5 | Flutter стоїть не в `E:\flutter`, а в `F:\Adndroid\FlutterNew` (диска E: на машині немає). Наявний `F:\Adndroid\Flutter` — 3.32.5, що менше за мінімум 3.44 для `flutter_foreground_task` 11.x, тому встановлено 3.47.2 stable окремо. SHA-256 архіву звірено з офіційним маніфестом. |
| 2026-09-05 | 5 | Android SDK уже встановлено в `F:\Adndroid\SDK` (platform-tools, platforms 23–36, build-tools 34–36). Ліцензії Google **уже прийнято** — крок **[ЛЮДИНА]** не знадобився. `GRADLE_USER_HOME` — `F:\Adndroid\gradle`. |
| 2026-09-05 | 4, 7.10 | `TaskStarter` у `flutter_foreground_task` 11.0.2 має лише значення `developer` і `system`; `TaskStarter.boot` не існує — запуск після перезавантаження приходить як `system`. Решта сигнатур `TaskHandler` збіглася зі специфікацією. |
| 2026-09-05 | 7.10 | `startService` повертає sealed-клас `ServiceRequestResult` (`ServiceRequestSuccess` / `ServiceRequestFailure`), а не об'єкт із полями `success`/`error`. Тип сервісу `specialUse` задано і в маніфесті, і через `serviceTypes:` у `startService`. |
| 2026-09-05 | 7.7 | `getMessageLink`: `poll_option_id` надіслано як `0` (int32 за схемою), а не як `""` — рядок у це поле схема не приймає. |
| 2026-09-05 | 7.7, 9.1 | `fallbackLink(chatId, messageId)` приймає **серверний** id повідомлення, тому тест зі специфікації (`fallbackLink(-1001234567890, 55)`) проходить без змін. TDLib зсуває id на 20 біт, тож пайплайн викликає `fallbackLink(chatId, serverMessageId(message.id))`. Додано хелпер `serverMessageId`. |
| 2026-09-05 | M0.4 / 9.3 | `ndk { abiFilters }` і `flutter build apk --split-per-abi` **несумісні** в AGP 9 (`Conflicting configuration ... in ndk abiFilters cannot be present when splits abi filters are set`). Оскільки специфікація вимагає `--split-per-abi`, `abiFilters` прибрано: набір ABI і так визначається вмістом `jniLibs` (три ABI), а x86 Flutter не збирає. |
| 2026-09-05 | 8 | **APK `arm64-v8a` — 48.2 МБ замість орієнтира ≤ 40 МБ.** Причина: `libtdjson.so` (30.5 МБ) пакується без стиснення, як вимагають сучасні налаштування пакування (пряме mmap і сумісність зі сторінками 16 КБ). Бібліотека вже без символів (`.symtab` та `.debug_*` відсутні), тож стиснути її стрипом неможливо. Якщо розмір файлу критичний, `useLegacyPackaging = true` дасть ≈28 МБ, але ціною розпакування другої копії бібліотеки на диск пристрою при встановленні. Залишено сучасне пакування. |
| 2026-09-05 | 7.10 | Додано захист від подвійного `_bootstrap()`: `onStart` і `ui.attached`, що приходить одразу після нього, могли створити **два** TDLib-клієнти на одній базі (заборонено рішенням R4). Тепер бутстрап однопотоковий (`_ensureBootstrapped`). |
| 2026-09-05 | M0.6 | Перевірка `libtdjson` винесена **до** перевірки `api_id`/`api_hash`, щоб непрацездатна бібліотека була видна в журналі одразу, а не лише після введення ключів. |
| 2026-09-05 | 7.8, 9.1 | Винятки `-слово` (позначені в специфікації як M5) реалізовано одразу: вони перелічені в обов'язковій таблиці тестів 9.1 і коштують кількох рядків. |
| 2026-09-05 | 6.4 | Посилання на оригінал копіюється в буфер обміну по тапу (`url_launcher` не додано — специфікація дозволяє обидва варіанти). |
| 2026-09-05 | 6.5, M5 | Кнопку «Стоп» у сповіщенні (позначену як необов'язкову) реалізовано на запит власника. Вона з'являється лише поки моніторинг активний, і зупиняє саме моніторинг, а не сервіс: `monitoringActive` скидається, тож після перезавантаження телефону моніторинг мовчки не відновиться. |
| 2026-09-05 | 7.9 | На запит власника ключові слова в пересланому повідомленні виводяться як теги (`#білогородка`), а не через кому: так у цільовому каналі можна фільтрувати за конкретним словом. Пробіли й дефіси стають підкресленнями (`тест-ключ` -> `#тест_ключ`), бо Telegram обриває тег на них; слово, з якого не лишається нічого придатного для тега (лише цифри чи пунктуація), виводиться як екранований текст. |
| 2026-09-05 | 6.1, 7.11 | Цільовий канал обирається випадаючим списком. Bot API не має методу «перелічити мої чати», тому кандидати шукаються через сесію власника в TDLib: канали, де цей бот має право публікації (`getChatMember` + `can_post_messages`). Це працює незалежно від того, коли бота додали, на відміну від `getUpdates`, який бачить лише останні 24 години. Потрібно, щоб власник був адміністратором каналу; ручне введення id залишено як запасний варіант. |
| 2026-09-05 | 7.11 | Додано команду `monitor.config`: зміни ключових слів застосовуються до запущеного моніторингу негайно. Раніше UI писав їх лише в SharedPreferences, тож вони діяли аж після перезапуску пошуку, а чергове перечитування папки могло записати старий список назад поверх нового. |

Телефон власника: модель **Samsung SM-G973F (Galaxy S10)**, Android **12 (API 31)**,
ABI **arm64-v8a**, розмір сторінки пам'яті **4096 байт** (тобто питання 16 КБ
на цьому пристрої не виникає; сама бібліотека все одно вирівняна на `0x4000`).

Перевірено на пристрої (2026-09-05): застосунок встановлюється і стартує,
foreground-сервіс піднімається (`isForeground=true`, сповіщення id 4242,
канал `tg_alert_monitor`), у журналі — `libtdjson loaded, tdlib 1.8.65`.
Тести T1–T14 з розділу 9.4 виконує власник: вони потребують реального
акаунта Telegram, бота і каналів.

---

## 14. Довідник

- TDLib JSON-інтерфейс: https://core.telegram.org/tdlib/docs/td__json__client_8h.html
- Схема API (master; для 1.8.65 усі використані тут назви збігаються): https://github.com/tdlib/td/blob/master/td/generate/scheme/td_api.tl
- Довідник методів/типів TDLib: https://core.telegram.org/tdlib/docs/classtd_1_1td__api_1_1_function.html
- Готові бінарники: https://github.com/up9cloud/android-libtdjson/releases (v1.8.65, `jniLibs.tar.gz`)
- Приклад FFI-обгортки (MIT), звідки взято сигнатури: https://github.com/up9cloud/flutter_libtdjson/blob/master/lib/client.dart
- `flutter_foreground_task`: https://pub.dev/packages/flutter_foreground_task
- Bot API: https://core.telegram.org/bots/api#sendmessage , ліміти: https://core.telegram.org/bots/faq#my-bot-is-hitting-limits-how-do-i-avoid-this
- Foreground service types і ліміти Android 15: https://developer.android.com/develop/background-work/services/fgs/service-types
- 16 КБ сторінки: https://developer.android.com/guide/practices/page-sizes
- Отримання api_id/api_hash: https://my.telegram.org
