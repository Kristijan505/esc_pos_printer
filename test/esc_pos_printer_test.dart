import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:esc_pos_printer/esc_pos_printer.dart';
import 'package:esc_pos_utils/esc_pos_utils.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late CapabilityProfile profile;

  setUpAll(() async {
    profile = await CapabilityProfile.load();
  });

  group('NetworkPrinter.connect', () {
    test('connects with explicit port', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        await server.close();
      });

      final accepted = Completer<void>();
      server.listen((Socket client) {
        client.destroy();
        if (!accepted.isCompleted) {
          accepted.complete();
        }
      });

      final printer = NetworkPrinter(PaperSize.mm80, profile);
      final result = await printer.connect(
        InternetAddress.loopbackIPv4.address,
        port: server.port,
      );

      expect(result, PosPrintResult.success);
      expect(printer.port, server.port);
      await accepted.future.timeout(const Duration(seconds: 2));

      printer.disconnect();
    });

    test('uses 9100 as the default port when omitted', () async {
      final printer = NetworkPrinter(PaperSize.mm80, profile);

      final result = await printer.connect(
        '203.0.113.1',
        timeout: const Duration(milliseconds: 200),
      );

      expect(printer.port, 9100);
      expect(result, PosPrintResult.timeout);
    });

    test('returns timeout when host is unreachable', () async {
      final printer = NetworkPrinter(PaperSize.mm80, profile);

      final result = await printer.connect(
        '256.256.256.256',
        timeout: const Duration(milliseconds: 100),
      );

      expect(result, PosPrintResult.timeout);
    });
  });

  group('NetworkPrinter.flush', () {
    test('surfaces a broken connection instead of pretending success',
        () async {
      // `disconnect` swallows this error so teardown cannot fail, which means
      // a print would otherwise be logged as delivered even though the peer
      // was gone. `flush` is what lets the caller notice.
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        await server.close();
      });

      final gone = Completer<void>();

      server.listen((Socket client) {
        client.destroy();
        if (!gone.isCompleted) gone.complete();
      });

      final printer = NetworkPrinter(PaperSize.mm80, profile);
      await printer.connect(
        InternetAddress.loopbackIPv4.address,
        port: server.port,
      );

      await gone.future.timeout(const Duration(seconds: 5));

      // Big enough that it cannot all sit in the send buffer unnoticed.
      printer.rawBytes(List<int>.filled(4 * 1024 * 1024, 0x41));

      await expectLater(printer.flush(), throwsA(isA<SocketException>()));
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('is a no-op when connect never succeeded', () async {
      final printer = NetworkPrinter(PaperSize.mm80, profile);

      await printer.connect(
        '256.256.256.256',
        timeout: const Duration(milliseconds: 100),
      );

      await expectLater(printer.flush(), completes);
    });
  });

  group('NetworkPrinter.disconnect', () {
    test('is safe when connect never succeeded', () async {
      // `PrintExecution._izvrsiMreza` always calls `disconnect` in a `finally`,
      // including the path where `connect` returned `timeout`. Blowing up there
      // hides the real failure behind a LateInitializationError.
      final printer = NetworkPrinter(PaperSize.mm80, profile);

      final result = await printer.connect(
        '256.256.256.256',
        timeout: const Duration(milliseconds: 100),
      );

      expect(result, PosPrintResult.timeout);

      await expectLater(printer.disconnect(delayMs: 1), completes);

      // Calling it twice must not blow up either.
      await expectLater(printer.disconnect(), completes);
    });

    test('delivers everything written even when the printer reads slowly',
        () async {
      // `disconnect` used to call `Socket.destroy()` straight away, which
      // discards whatever has not reached the socket yet. A receipt bigger
      // than the send buffer was therefore truncated without any error --
      // the printer simply printed half a ticket.
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        await server.close();
      });

      final received = BytesBuilder();
      final closed = Completer<void>();

      server.listen((Socket client) {
        final subscription = client.listen(
          received.add,
          onDone: () {
            if (!closed.isCompleted) closed.complete();
          },
          onError: (Object _) {
            if (!closed.isCompleted) closed.complete();
          },
        );

        // A printer that does not read for two seconds: the send buffer
        // fills up and the rest stays queued inside the Dart socket.
        subscription.pause();
        Timer(const Duration(seconds: 2), subscription.resume);
      });

      final generator = Generator(PaperSize.mm80, profile);
      final ticket = <int>[
        for (var i = 0; i < 20000; i++)
          ...generator.text('Line number $i with some padding to widen it'),
        ...generator.cut(),
      ];

      final printer = NetworkPrinter(PaperSize.mm80, profile);
      await printer.connect(
        InternetAddress.loopbackIPv4.address,
        port: server.port,
      );

      printer.rawBytes(ticket);
      await printer.disconnect();

      await closed.future.timeout(const Duration(seconds: 30));

      expect(received.toBytes().length, greaterThanOrEqualTo(ticket.length));
    }, timeout: const Timeout(Duration(seconds: 60)));
  });

  group('NetworkPrinter.queryStatus', () {
    test('returns the byte the printer answers with', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        await server.close();
      });

      server.listen((Socket client) {
        client.listen((Uint8List data) {
          // Odgovara jednim bajtom, kao stvarni DLE EOT odgovor.
          client.add([0x12]);
        });
      });

      final printer = NetworkPrinter(PaperSize.mm80, profile);
      await printer.connect(
        InternetAddress.loopbackIPv4.address,
        port: server.port,
      );
      addTearDown(() => printer.disconnect());

      final result = await printer.queryStatus(
        [0x10, 0x04, 0x01],
        maxBytes: 1,
        timeout: const Duration(seconds: 2),
      );

      expect(result, Uint8List.fromList([0x12]));
    });

    test('returns an empty result when the printer stays silent', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        await server.close();
      });

      server.listen((Socket client) {
        // Namjerno ne odgovara -- printer koji ne podrzava upit.
        client.listen((Uint8List _) {});
      });

      final printer = NetworkPrinter(PaperSize.mm80, profile);
      await printer.connect(
        InternetAddress.loopbackIPv4.address,
        port: server.port,
      );
      addTearDown(() => printer.disconnect());

      final result = await printer.queryStatus(
        [0x10, 0x04, 0x01],
        timeout: const Duration(milliseconds: 100),
      );

      expect(result, isEmpty);
    });

    test('throws when the connection breaks while waiting', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        await server.close();
      });

      server.listen((Socket client) {
        client.listen((Uint8List _) {
          // Prekida vezu umjesto da odgovori.
          client.destroy();
        });
      });

      final printer = NetworkPrinter(PaperSize.mm80, profile);
      await printer.connect(
        InternetAddress.loopbackIPv4.address,
        port: server.port,
      );
      addTearDown(() => printer.disconnect());

      await expectLater(
        printer.queryStatus(
          [0x10, 0x04, 0x01],
          timeout: const Duration(seconds: 2),
        ),
        throwsA(anything),
      );
    });

    test('throws when there is no connection', () async {
      final printer = NetworkPrinter(PaperSize.mm80, profile);

      await expectLater(
        printer.queryStatus([0x10, 0x04, 0x01]),
        throwsA(isA<StateError>()),
      );
    });

    test('a one-byte reply returns well before a long timeout', () async {
      // `timeout` je rok samo za prvi bajt; jednom kad printer odgovori,
      // ne smije se cekati puni `timeout` (bitno za `GS r` gdje je taj
      // rok namjerno postavljen na nekoliko sekundi).
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        await server.close();
      });

      server.listen((Socket client) {
        client.listen((Uint8List _) {
          client.add([0x12]);
        });
      });

      final printer = NetworkPrinter(PaperSize.mm80, profile);
      await printer.connect(
        InternetAddress.loopbackIPv4.address,
        port: server.port,
      );
      addTearDown(() => printer.disconnect());

      final stopwatch = Stopwatch()..start();
      final result = await printer.queryStatus(
        [0x10, 0x04, 0x01],
        maxBytes: 1,
        timeout: const Duration(seconds: 5),
      );
      stopwatch.stop();

      expect(result, Uint8List.fromList([0x12]));
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 1)));
    });

    test('a multi-byte reply is returned whole once it stops arriving',
        () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        await server.close();
      });

      server.listen((Socket client) {
        client.listen((Uint8List _) async {
          // Salje odgovor bajt po bajt s malim razmakom, da se provjeri da
          // `grace` ceka do zadnjeg bajta, a ne prekine na prvom.
          for (final byte in const [0x01, 0x02, 0x03, 0x04]) {
            client.add([byte]);
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
        });
      });

      final printer = NetworkPrinter(PaperSize.mm80, profile);
      await printer.connect(
        InternetAddress.loopbackIPv4.address,
        port: server.port,
      );
      addTearDown(() => printer.disconnect());

      final result = await printer.queryStatus(
        [0x10, 0x04, 0x01],
        timeout: const Duration(seconds: 2),
      );

      expect(result, Uint8List.fromList([0x01, 0x02, 0x03, 0x04]));
    });

    test('rejects an overlapping call while one is in progress', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        await server.close();
      });

      server.listen((Socket client) {
        // Namjerno ne odgovara, da prvi poziv ostane u tijeku.
        client.listen((Uint8List _) {});
      });

      final printer = NetworkPrinter(PaperSize.mm80, profile);
      await printer.connect(
        InternetAddress.loopbackIPv4.address,
        port: server.port,
      );
      addTearDown(() => printer.disconnect());

      final first = printer.queryStatus(
        [0x10, 0x04, 0x01],
        timeout: const Duration(milliseconds: 300),
      );

      final overlapping = printer.queryStatus([0x10, 0x04, 0x01]);

      await expectLater(overlapping, throwsA(isA<StateError>()));
      await expectLater(first, completion(isEmpty));
    });
  });
}
