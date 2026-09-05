# TG Alert Monitor

An Android app that watches the channels in a Telegram folder of your choosing
and reacts to messages containing your keywords the way you tell it to: by
forwarding them into your own channel, by raising a siren on this phone, or by
doing both.

Built to [SPEC.md](SPEC.md) (Ukrainian). The app's interface is available in
Ukrainian and English, and follows the device language.

---

## What it does

1. Signs in to Telegram **as a user** (through TDLib) — a bot cannot see the
   messages of channels it does not own.
2. You pick a Telegram folder from a list and enter keywords
   (`шахед`, `балістика`, `Бровар`…).
3. After «Start» a foreground service reads new messages in that folder's
   chats — with the screen off, after the app is swiped out of Recents, and
   after the phone reboots.
4. When a message's text or caption contains a keyword, the delivery mode you
   picked kicks in (see below): the original is forwarded into your target
   channel under your own name (keeping the "Forwarded from…" header and any
   media), and/or a notification with a siren goes off on this phone.

---

## What you need first

| Detail | Where to get it |
|--------|-----------------|
| `api_id`, `api_hash` | https://my.telegram.org → API development tools → create an application (platform: Android) |
| Target channel | Create a private channel where **you** are an administrator with the "Post messages" right. It is picked from a list in the settings, and is only needed for the "Forward" and "Both" modes |

No bot is involved: delivery goes through your own Telegram session.

---

## Installing

The APK is signed with the debug key of whichever machine built it
(`~/.android/debug.keystore`), so updates install over the previous build as
long as you keep building on the same machine.

```bash
adb install -r build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
```

`arm64-v8a` is the one you want for most modern phones.

## First-time setup

1. Open the app → the gear icon, «Settings».
2. Enter `api_id` and `api_hash` → **Save**.
3. The «Telegram sign-in required» card → phone number → code → 2FA password
   if you have one.
4. Back in the settings → **«Find my channels»** → pick the target channel
   from the list. **«Test message»** sends a test down exactly the same path a
   real alert takes.
5. On the home screen, pick a **Telegram folder** from the list; «Show chats»
   reveals which chats it contains (channels are marked with 📢).
6. Add your keywords (Enter or «+»), then hit **«Start»**.

The login lives in the TDLib database, so restarting the app does not ask you
to sign in again.

### Permissions — not optional

Without these, Android will stop the monitoring:

* **Notifications** — the service's persistent notification is the condition
  for it running in the background at all.
* **Battery optimisation — disable it** (there is a button on the home
  screen).
* Xiaomi / Huawei / Samsung: in the system settings for the app, enable
  **"Autostart"**, set the battery mode to **"Unrestricted"**, and pin the app
  in the Recents list.

---

## How matching works

* A match is a **case-insensitive substring**. `шахед` finds `Шахеди`,
  `ШАХЕДІВ`, `шахедами`.
* A keyword is reduced to its **stem**, so declined forms are covered:
  `Білогородка` is searched for as `білогород`, which finds «на Білогородку»,
  «у Білогородці», «над Білогородкою». The stem is shown in grey on the chip —
  the guess is never applied invisibly.
* The ending is trimmed, and so is a `к`/`г`/`х` in front of it: those
  alternate in the locative case (Білогород**к**а → у Білогород**ц**і), so the
  stem has to end before them.
* **To set the stem yourself, enter a word ending in a consonant.** Those are
  left alone: `перемог` stays `перемог`.
* The stemmer is simple and deliberately knows no morphology. Sometimes the
  stem comes out shorter than you would like (`місто` → `міст`, which collides
  with the word "bridge"). That is exactly why the stem is visible in the UI.
* Whitespace and line breaks are normalised, so `балістика на` also matches
  text split across two lines. Multi-word phrases are never shortened.
* **Exclusion words** get their own section on the home screen. A message
  containing one does not trigger, even when a keyword is present too (say
  «відбій», «збито»). They are stored with a `-` prefix.

The keyword that matched is shown in the journal as a **hashtag**
(`#білогородка`). Spaces and hyphens inside a tag become underscores
(`тест-ключ` → `#тест_ключ`), because Telegram cuts a tag off at a space or a
hyphen.

## How to be alerted: a three-position switch

The «Notifications» card on the home screen:

| Position | What it does |
|----------|--------------|
| **Forward** | The original is forwarded into the target channel. The phone stays quiet. |
| **Local** | A notification in this phone's shade plus the siren. Nothing is forwarded, and no target channel is needed. |
| **Both** | Forwarding and the siren. |

The switch takes effect immediately — you can flip it while monitoring is
running.

The siren is `assets/siren_ostap_calm.ogg`. Android itself plays it, as the
sound of the "keyword matches" notification channel, with alarm audio
attributes — so it is audible even with the phone on silent. Volume, vibration
and importance can be changed in that channel's system settings.

## Who posts the alert: you, or a bot

By default the app forwards the original **as you**, through your own Telegram
session. That keeps the "Forwarded from" header and the media, and needs no bot
at all.

It has one consequence worth knowing: **a message you send never notifies your
own other devices.** If you are watching the target channel from a second phone,
your own forwards arrive there silently.

Setting a **bot token** in the settings fixes that. A bot is a different sender,
so its post raises a normal notification on your phones. A bot cannot forward
from channels it is not in, so in this mode the alert is a rendered message —
the tags, the text, and a link back to the original — rather than a forward.

Get the token from @BotFather and add the bot as an administrator of the target
channel with the "Post messages" right. Leave the field empty to keep
forwarding as yourself.

## What a forward looks like

The original goes across as a real forward: with the "Forwarded from <channel>"
header, with its media, and without the text being retyped. Nothing else is
posted alongside it — the tags are visible in the app's journal.

If the source channel forbids forwarding (`has_protected_content`), a text
copy with a link to the original is sent instead, so the alert is not lost.

## Setting up a second phone

The first phone shows a QR code (the ⧉ menu in the app bar → «Share this
setup»), the second one scans it (→ «Take setup from another phone»). The
second phone then subscribes to the channels it is not in yet, gathers them
into a folder of the same name, copies the keywords, and switches itself to
**Local** mode — a second phone is there to raise a siren, not to relay into a
channel it has no rights in.

It asks before doing any of it: joining channels on someone's Telegram account
is not something to do straight off a camera frame. If that phone is not signed
in to Telegram yet, the scanned code is held until it is.

**Only public channels travel.** The receiving account has never seen these
chats, so a numeric id means nothing to its TDLib — a `@username` is what it can
resolve and join, and a private channel has none. Those are listed by name on
the sharing screen so you know to add them by hand.

The code carries channel usernames, keywords, the folder name and the maximum
message age. It carries no credentials: `api_id`, `api_hash` and the Telegram
session stay on their own phone.

## Diagnostics

The journal's third tab, «Diagnostics», for when a keyword was posted and
nothing happened:

* **What is being watched** — whether monitoring is actually on, and which
  chats the engine currently holds. The chat list is re-resolved every half
  hour, so a channel added to the folder a minute ago is not watched yet;
  «Refresh the chat list» does it now.
* **Try some text** — runs the real matcher over pasted text and says which
  keyword fired, or that an exclusion word blocked it. It lists the keywords
  **the service** holds, which is not always what the home screen still shows.
* **Test the siren** — fires a local notification through the real notifier.
* **Test delivery** — takes the newest message from a watched chat and sends it
  down exactly the path a real alert takes, forward or bot.

## Journal

On the «Matches» tab, a **tap** opens the message in Telegram and a **long
press** copies its link.

## What does not trigger

A message is dropped when: its chat is not in the folder; it is your own
message; it has neither text nor a caption (a sticker, a poll); it is older
than "Maximum message age" (which protects against an avalanche after a
reconnect); or the same message has already been handled. Editing a message
that was already handled does **not** send it again.

---

## Development

Requires the Flutter SDK and the Android SDK. Point your shell at them the way
your platform expects — for example, on Windows with PowerShell:

```powershell
$env:Path = "<flutter-sdk>\bin;$env:Path"
$env:ANDROID_HOME = "<android-sdk>"
```

Checks:

```bash
flutter analyze
dart format --set-exit-if-changed lib test
flutter test
```

Build:

```bash
flutter build apk --release --split-per-abi
```

### Layout

| Directory | What is in it |
|-----------|---------------|
| `lib/core/td/` | FFI to `libtdjson.so`, the receive isolate, request/response correlation by `@extra` |
| `lib/core/bot/` | Message rendering and the send queue with its rate limits and retries |
| `lib/core/matcher/` | Keyword matching |
| `lib/core/ipc/` | The UI ↔ service protocol |
| `lib/service/` | `MonitorEngine` (all the logic, no Flutter) and the foreground service's `TaskHandler` |
| `lib/ui/` | Screens and the bridge to the service |
| `lib/core/model/setup_payload.dart` | What the setup QR code carries |
| `lib/l10n/` | Ukrainian and English interface strings (`.arb`) |

`lib/core/` and `MonitorEngine` do not depend on Flutter and are covered by
ordinary tests with hand-written fakes (`test/fakes/`).

`app_uk.arb` is the template and `app_en.arb` the translation — Ukrainian is
the source of truth. `app_localizations*.dart` is generated from them by
`flutter pub get`, and is not in git. Because the engine may not import
Flutter, its own strings are declared as a plain-Dart `EngineStrings`
interface; `test/l10n_test.dart` checks that its Ukrainian default and the
`.arb` files have not drifted apart.

### TDLib

Prebuilt **v1.8.65** binaries from
[up9cloud/android-libtdjson](https://github.com/up9cloud/android-libtdjson/releases),
placed in `android/app/src/main/jniLibs/<abi>/libtdjson.so`.

The `.so` files themselves (81 MB) are not kept in git. After cloning, run:

```bash
bash scripts/fetch_tdlib.sh
```

The script verifies the archive's SHA-256 and refuses to install anything else.

```
jniLibs.tar.gz
  size    42 825 897 bytes
  SHA-256 eb777d3e7baedeb02871c691b2090daa1bc51baf9215a81bc55bf54edb76df2b
```

The `LOAD` segments in `libtdjson.so` are aligned to `0x4000`, so the library
works on phones with 16 KB memory pages.

**The TDLib client is only ever created in the service isolate.** The UI never
opens `libtdjson.so`: two clients over one database are not allowed.
