import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tg_alert_monitor/core/model/setup_payload.dart';

const _payload = SetupPayload(
  folderName: 'Тривога',
  channels: [
    SetupChannel(username: 'kyiv_alarm', title: 'Київ • Тривога'),
    SetupChannel(username: 'war_monitor', title: 'Монітор'),
  ],
  keywords: ['шахед', 'балістика', '-відбій'],
  maxAgeMinutes: 15,
);

void main() {
  test('a payload survives a round trip through the QR encoding', () {
    final restored = SetupPayload.decode(_payload.encode());

    expect(restored.folderName, 'Тривога');
    expect(restored.channels, _payload.channels);
    expect(restored.keywords, ['шахед', 'балістика', '-відбій']);
    expect(restored.maxAgeMinutes, 15);
  });

  /// Roughly what a heavy user has: 25 channels and 40 keywords.
  SetupPayload big() => SetupPayload(
    folderName: 'Тривога',
    channels: [
      for (var i = 0; i < 25; i++)
        SetupChannel(username: 'alarm_channel_$i', title: 'Канал номер $i'),
    ],
    keywords: [for (var i = 0; i < 40; i++) 'ключове слово $i'],
  );

  test('a heavy setup still fits in a scannable code', () {
    expect(big().encode().length, lessThan(SetupPayload.maxEncodedLength));
  });

  test('gzip is what makes a heavy setup fit at all', () {
    // Uncompressed, the same payload is ~3.5 kB of base64 — beyond what any
    // QR code can hold (2953 bytes), let alone one readable across a room.
    // Cyrillic costs two bytes a character in UTF-8 and the JSON keys repeat,
    // so this is not a marginal saving.
    final payload = big();
    final uncompressed = base64Url.encode(
      utf8.encode(jsonEncode(payload.toJson())),
    );

    expect(uncompressed.length, greaterThan(2953));
    expect(payload.encode().length * 4, lessThan(uncompressed.length));
  });

  group('decode rejects', () {
    test('a QR code from somewhere else', () {
      expect(
        () => SetupPayload.decode('https://example.com'),
        throwsA(isA<SetupPayloadError>()),
      );
    });

    test('our prefix with garbage behind it', () {
      expect(
        () => SetupPayload.decode('${SetupPayload.prefix}not-base64!!'),
        throwsA(isA<SetupPayloadError>()),
      );
    });

    test('valid base64 that is not gzip', () {
      expect(
        () => SetupPayload.decode('${SetupPayload.prefix}aGVsbG8='),
        throwsA(isA<SetupPayloadError>()),
      );
    });

    test('an empty string', () {
      expect(() => SetupPayload.decode(''), throwsA(isA<SetupPayloadError>()));
    });
  });

  test('surrounding whitespace from a scanner is tolerated', () {
    final restored = SetupPayload.decode('  ${_payload.encode()}\n');
    expect(restored.channels, _payload.channels);
  });

  test('missing fields decode to harmless defaults', () {
    const bare = SetupPayload();
    final restored = SetupPayload.decode(bare.encode());

    expect(restored.isEmpty, isTrue);
    expect(restored.folderName, isEmpty);
    expect(restored.maxAgeMinutes, 10);
  });

  test('a username keeps no leading @', () {
    // The engine passes this straight to searchPublicChat, which wants it bare.
    final restored = SetupPayload.decode(_payload.encode());
    expect(restored.channels.first.username, 'kyiv_alarm');
  });
}
