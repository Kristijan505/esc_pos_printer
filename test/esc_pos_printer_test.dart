import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:esc_pos_printer/esc_pos_printer.dart';
import 'package:esc_pos_utils/esc_pos_utils.dart';
import 'package:flutter_test/flutter_test.dart';

/// Testni serveri koriste ovo da NE odgovore na `reset()` koji [connect]
/// posalje prije svakog upita -- odgovor na pogresan bajt bi test ucinio
/// tihim krivo-pozitivnim, umjesto da stvarno provjeri upit.
bool _looksLikeStatusQuery(List<int> data) {
  for (var i = 0; i + 1 < data.length; i++) {
    if (data[i] == 0x10 && data[i + 1] == 0x04) return true;
  }
  return false;
}

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
        final received = BytesBuilder();
        var replied = false;
        client.listen((Uint8List data) {
          if (replied) return;
          received.add(data);
          // Ne odgovara na `reset()` koji connect() salje prije upita --
          // samo na stvarni upit statusa.
          if (!_looksLikeStatusQuery(received.toBytes())) return;
          replied = true;
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
        final received = BytesBuilder();
        var replied = false;
        client.listen((Uint8List data) {
          if (replied) return;
          received.add(data);
          if (!_looksLikeStatusQuery(received.toBytes())) return;
          replied = true;
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
        final received = BytesBuilder();
        var replied = false;
        client.listen((Uint8List data) async {
          if (replied) return;
          received.add(data);
          if (!_looksLikeStatusQuery(received.toBytes())) return;
          replied = true;

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

    test('a printer that never reads does not hang the call forever',
        () async {
      // `timeout` sada pokriva i samo slanje: printer koji nikad ne cita
      // puni TCP prozor, pa `flush()` moze visjeti zauvijek -- upravo
      // takvog printera zelimo prijaviti kao "ne odgovara" umjesto da
      // queryStatus visi zauvijek.
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        await server.close();
      });

      server.listen((Socket client) {
        // Printer koji nikad ne cita -- pauzira pretplatu odmah, pa se
        // primljeno ne prazni i TCP prozor se puni.
        client.listen((Uint8List _) {}).pause();
      });

      final printer = NetworkPrinter(PaperSize.mm80, profile);
      await printer.connect(
        InternetAddress.loopbackIPv4.address,
        port: server.port,
      );
      addTearDown(() => printer.disconnect());

      final stopwatch = Stopwatch()..start();
      final result = await printer.queryStatus(
        List<int>.filled(8 * 1024 * 1024, 0x00),
        timeout: const Duration(milliseconds: 300),
      );
      stopwatch.stop();

      expect(result, isEmpty);
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 5)));
    }, timeout: const Timeout(Duration(seconds: 15)));

    test('a query after a failed send does not get stuck as "overlapping"',
        () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        await server.close();
      });

      server.listen((Socket client) {
        client.destroy();
      });

      final printer = NetworkPrinter(PaperSize.mm80, profile);
      await printer.connect(
        InternetAddress.loopbackIPv4.address,
        port: server.port,
      );
      addTearDown(() => printer.disconnect());

      // Prvi upit: veza puca dok se salje/ceka -- baca gresku. `socket.add`
      // i `flush()` su sada UNUTAR try/finally, pa greska ovdje ne smije
      // ostaviti `_statusCompleter` zauvijek postavljenim.
      await expectLater(
        printer.queryStatus(
          [0x10, 0x04, 0x01],
          timeout: const Duration(seconds: 2),
        ),
        throwsA(anything),
      );

      // Drugi upit odmah nakon ne smije pasti na "preklapanje" -- state iz
      // prvog poziva mora biti pociscen bez obzira kojim je putem prvi
      // pukao.
      Object? secondError;
      try {
        await printer.queryStatus(
          [0x10, 0x04, 0x01],
          timeout: const Duration(milliseconds: 200),
        );
      } catch (e) {
        secondError = e;
      }

      expect(secondError.toString(), isNot(contains('preklapaju')));
    });

    test('disconnect while a query is pending makes it throw', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        await server.close();
      });

      server.listen((Socket client) {
        // Nikad ne odgovara -- upit ostaje visjeti dok ga disconnect() ne
        // prekine.
        client.listen((Uint8List _) {});
      });

      final printer = NetworkPrinter(PaperSize.mm80, profile);
      await printer.connect(
        InternetAddress.loopbackIPv4.address,
        port: server.port,
      );

      final pending = printer.queryStatus(
        [0x10, 0x04, 0x01],
        timeout: const Duration(seconds: 5),
      );
      // Ocekivanje se vezuje ODMAH, prije bilo kojeg await-a -- inace Dart
      // asinkroni Future koji jos nema slusatelja prijavi kao neuhvacenu
      // gresku prije nego stignemo ovdje dolje pozvati expectLater.
      final pendingThrows = expectLater(pending, throwsA(anything));

      // Da upit sigurno bude u cekanju prije diskonekcije.
      await Future<void>.delayed(const Duration(milliseconds: 50));

      await printer.disconnect();

      await pendingThrows;
    });

    test('reconnecting without disconnect() isolates the new connection',
        () async {
      final serverA =
          await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        await serverA.close();
      });

      Socket? clientA;
      serverA.listen((Socket client) {
        clientA = client;
        addTearDown(client.destroy);
        // Server A namjerno ne odgovara. connect() fix namjerno ne gasi
        // stari socket (samo staru pretplatu) -- ostaje otvoren dok ga
        // teardown ne unisti. Pisanje u njega kasnije u testu (nakon sto
        // je klijent vec presao na B) zna zavrsiti greskom na `done` (peer
        // je vec efektivno napusten), a to NIJE neuhvacena greska koju
        // treba prijaviti.
        unawaited(client.done.catchError((_) {}));
        client.listen((Uint8List _) {}, onError: (Object _) {});
      }, onError: (Object _) {});

      final printer = NetworkPrinter(PaperSize.mm80, profile);
      await printer.connect(
        InternetAddress.loopbackIPv4.address,
        port: serverA.port,
      );

      final pendingOnA = printer.queryStatus(
        [0x10, 0x04, 0x01],
        timeout: const Duration(seconds: 5),
      );
      // Ocekivanje se vezuje ODMAH, prije bilo kojeg await-a -- inace Dart
      // asinkroni Future koji jos nema slusatelja prijavi kao neuhvacenu
      // gresku prije nego stignemo dolje pozvati expectLater.
      final pendingOnAThrows = expectLater(pendingOnA, throwsA(anything));

      // Da se upit sigurno uhvati u cekanju prije reconnecta.
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final serverB =
          await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        await serverB.close();
      });
      serverB.listen((Socket client) {
        // Server B takodjer ne odgovara -- upit na njemu mora isteci
        // prazan.
        client.listen((Uint8List _) {});
      });

      // Reconnect BEZ disconnect() -- upit na A mora pasti greskom.
      final reconnectResult = await printer.connect(
        InternetAddress.loopbackIPv4.address,
        port: serverB.port,
      );
      expect(reconnectResult, PosPrintResult.success);
      addTearDown(() => printer.disconnect());

      await pendingOnAThrows;

      // Zakasnjeli bajt sa STAROG servera (A) ne smije dovrsiti upit na
      // NOVOJ vezi (B).
      clientA?.add([0xAA]);

      final resultOnB = await printer.queryStatus(
        [0x10, 0x04, 0x01],
        timeout: const Duration(milliseconds: 300),
      );

      expect(resultOnB, isEmpty);
    }, timeout: const Timeout(Duration(seconds: 15)));

    test('maxBytes truncates a larger single TCP event to the requested size',
        () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        await server.close();
      });

      server.listen((Socket client) {
        final received = BytesBuilder();
        var replied = false;
        client.listen((Uint8List data) {
          if (replied) return;
          received.add(data);
          if (!_looksLikeStatusQuery(received.toBytes())) return;
          replied = true;
          // Odgovara sa 4 bajta odjednom, u JEDNOM paketu.
          client.add([0x01, 0x02, 0x03, 0x04]);
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

      expect(result, Uint8List.fromList([0x01]));
    });

    test('a delayed reply to a timed-out query does not leak into the next '
        'one', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        await server.close();
      });

      var repliedOnce = false;
      server.listen((Socket client) {
        final received = BytesBuilder();
        client.listen((Uint8List data) {
          received.add(data);
          if (!_looksLikeStatusQuery(received.toBytes())) return;
          if (repliedOnce) return;
          repliedOnce = true;
          // Odgovara na PRVI upit tek 100 ms kasnije -- nakon sto ce
          // klijent vec biti odustao od njega (rok mu je 50 ms). Na drugi
          // upit se namjerno vise ne odgovara.
          Future<void>.delayed(const Duration(milliseconds: 100), () {
            client.add([0xAA]);
          });
        });
      });

      final printer = NetworkPrinter(PaperSize.mm80, profile);
      await printer.connect(
        InternetAddress.loopbackIPv4.address,
        port: server.port,
      );
      addTearDown(() => printer.disconnect());

      final firstResult = await printer.queryStatus(
        [0x10, 0x04, 0x01],
        timeout: const Duration(milliseconds: 50),
      );
      expect(firstResult, isEmpty);

      // Drugi upit ne dobiva odgovor od servera -- zakasnjeli bajt s prvog
      // upita ne smije zavrsiti njega.
      final secondResult = await printer.queryStatus(
        [0x10, 0x04, 0x01],
        timeout: const Duration(milliseconds: 300),
      );

      expect(secondResult, isEmpty);
    }, timeout: const Timeout(Duration(seconds: 10)));

    test('a query started while draining after a timeout still rejects '
        'overlap', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        await server.close();
      });

      server.listen((Socket client) {
        // Nikad ne odgovara.
        client.listen((Uint8List _) {});
      });

      final printer = NetworkPrinter(PaperSize.mm80, profile);
      await printer.connect(
        InternetAddress.loopbackIPv4.address,
        port: server.port,
      );
      addTearDown(() => printer.disconnect());

      // Prvi upit istekne bez odgovora -- postavlja zabiljesku o
      // neodgovorenom upitu, pa drugi upit mora prvo cekati tisinu.
      final firstResult = await printer.queryStatus(
        [0x10, 0x04, 0x01],
        timeout: const Duration(milliseconds: 50),
      );
      expect(firstResult, isEmpty);

      // Drugi upit odmah ulazi u cekanje tisine (zadani quietPeriod od
      // 150 ms), JOS PRIJE nego uopce posalje svoj zahtjev -- za to
      // vrijeme mora vec biti "u tijeku", inace bi treci upit prosao
      // preklapanje.
      final second = printer.queryStatus(
        [0x10, 0x04, 0x01],
        timeout: const Duration(seconds: 2),
      );
      // Ocekivanje se vezuje ODMAH, prije bilo kojeg await-a.
      final secondThrows = expectLater(second, throwsA(anything));

      // Da drugi upit sigurno vec bude u cekanju tisine.
      await Future<void>.delayed(const Duration(milliseconds: 30));

      await expectLater(
        printer.queryStatus([0x10, 0x04, 0x01]),
        throwsA(isA<StateError>()),
      );

      // Diskonektiraj da drugi upit zavrsi (baci) prije kraja testa.
      await printer.disconnect();
      await secondThrows;
    }, timeout: const Timeout(Duration(seconds: 10)));

    test('a burst of more than 256 bytes while draining is not mistaken '
        'for silence', () async {
      // `_incomingBuffer` je ogranicen na 256 bajtova dok nijedan upit ne
      // ceka -- ako se tisina mjeri po duljini spremnika, printer koji i
      // dalje salje (spremnik vec pun i stoji na stropu) izgleda lazno
      // tiho puno prije nego sto stvarno prestane.
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        await server.close();
      });

      var repliedOnce = false;
      server.listen((Socket client) {
        final received = BytesBuilder();
        client.listen((Uint8List data) async {
          received.add(data);
          if (!_looksLikeStatusQuery(received.toBytes())) return;
          if (repliedOnce) return;
          repliedOnce = true;

          // Ceka da klijent sigurno vec odustane od prvog upita (rok mu
          // je 30 ms), pa salje preko 256 bajtova u kapaljkama razvucenim
          // na oko 500 ms -- dulje od zadanog quietPeriod-a (150 ms). Na
          // drugi upit se namjerno vise ne odgovara.
          await Future<void>.delayed(const Duration(milliseconds: 80));
          for (var i = 0; i < 25; i++) {
            client.add(List<int>.filled(50, 0xFF));
            await Future<void>.delayed(const Duration(milliseconds: 20));
          }
        });
      });

      final printer = NetworkPrinter(PaperSize.mm80, profile);
      await printer.connect(
        InternetAddress.loopbackIPv4.address,
        port: server.port,
      );
      addTearDown(() => printer.disconnect());

      final firstResult = await printer.queryStatus(
        [0x10, 0x04, 0x01],
        timeout: const Duration(milliseconds: 30),
      );
      expect(firstResult, isEmpty);

      final stopwatch = Stopwatch()..start();
      final secondResult = await printer.queryStatus(
        [0x10, 0x04, 0x01],
        timeout: const Duration(milliseconds: 150),
      );
      stopwatch.stop();

      expect(secondResult, isEmpty);
      // Mlaz (80 ms zakasnjenja + ~500 ms slanja) plus quietPeriod (150 ms)
      // plus drugi upit svoj rok (150 ms) iznosi preko 700 ms -- mjereno
      // po pogresno ogranicenoj duljini spremnika, cekanje bi lazno
      // zavrsilo puno ranije.
      expect(stopwatch.elapsed, greaterThan(const Duration(milliseconds: 550)));
    }, timeout: const Timeout(Duration(seconds: 10)));

    test(
        'disconnect() + connect() while draining invalidates the stale '
        'query', () async {
      final serverA =
          await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        await serverA.close();
      });

      serverA.listen((Socket client) {
        // Server A nikad ne odgovara.
        client.listen((Uint8List _) {});
      });

      final printer = NetworkPrinter(PaperSize.mm80, profile);
      await printer.connect(
        InternetAddress.loopbackIPv4.address,
        port: serverA.port,
      );

      // Prvi upit istekne bez odgovora -- postavlja zabiljesku o
      // neodgovorenom upitu.
      final firstResult = await printer.queryStatus(
        [0x10, 0x04, 0x01],
        timeout: const Duration(milliseconds: 30),
      );
      expect(firstResult, isEmpty);

      // Drugi (zastarjeli) upit odmah ulazi u cekanje tisine na A, JOS
      // PRIJE nego uopce posalje bilo sto.
      final stale = printer.queryStatus(
        [0x10, 0x04, 0x01],
        timeout: const Duration(seconds: 2),
      );
      // Ocekivanje se vezuje ODMAH, prije bilo kojeg await-a.
      final staleThrows = expectLater(stale, throwsA(isA<StateError>()));

      // Da zastarjeli upit sigurno vec bude u cekanju tisine.
      await Future<void>.delayed(const Duration(milliseconds: 30));

      final serverB =
          await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        await serverB.close();
      });

      // Zastarjeli upit ne smije nista poslati serveru B -- provjeri se da
      // B ne primi upit statusa PRIJE nego sto novi upit uistinu krene.
      // (connect() svejedno salje reset() odmah, pa se to ne racuna.)
      var newQueryStarted = false;
      var unexpectedQueryBeforeNewQuery = false;
      final earlyBytes = BytesBuilder();
      final received = BytesBuilder();
      var repliedOnB = false;
      serverB.listen((Socket client) {
        client.listen((Uint8List data) {
          if (!newQueryStarted) {
            earlyBytes.add(data);
            if (_looksLikeStatusQuery(earlyBytes.toBytes())) {
              unexpectedQueryBeforeNewQuery = true;
            }
          }
          if (repliedOnB) return;
          received.add(data);
          if (!_looksLikeStatusQuery(received.toBytes())) return;
          repliedOnB = true;
          client.add([0x12]);
        });
      });

      // disconnect() + connect() na NOVI server, dok zastarjeli upit jos
      // ceka tisinu na starome.
      await printer.disconnect();
      final reconnectResult = await printer.connect(
        InternetAddress.loopbackIPv4.address,
        port: serverB.port,
      );
      expect(reconnectResult, PosPrintResult.success);
      addTearDown(() => printer.disconnect());

      // Zastarjeli upit mora baciti -- veza mu je zamijenjena ispod njega.
      await staleThrows;

      // Novi upit na NOVOJ vezi radi normalno.
      newQueryStarted = true;
      final result = await printer.queryStatus(
        [0x10, 0x04, 0x01],
        maxBytes: 1,
        timeout: const Duration(seconds: 2),
      );

      expect(result, Uint8List.fromList([0x12]));
      expect(unexpectedQueryBeforeNewQuery, isFalse);
    }, timeout: const Timeout(Duration(seconds: 15)));

    test('invalid arguments throw ArgumentError without changing state',
        () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        await server.close();
      });

      server.listen((Socket client) {
        final received = BytesBuilder();
        var replied = false;
        client.listen((Uint8List data) {
          if (replied) return;
          received.add(data);
          if (!_looksLikeStatusQuery(received.toBytes())) return;
          replied = true;
          client.add([0x12]);
        });
      });

      final printer = NetworkPrinter(PaperSize.mm80, profile);
      await printer.connect(
        InternetAddress.loopbackIPv4.address,
        port: server.port,
      );
      addTearDown(() => printer.disconnect());

      await expectLater(
        printer.queryStatus(<int>[]),
        throwsA(isA<ArgumentError>()),
      );
      await expectLater(
        printer.queryStatus([0x10, 0x04, 0x01], maxBytes: 0),
        throwsA(isA<ArgumentError>()),
      );
      await expectLater(
        printer.queryStatus([0x10, 0x04, 0x01], maxBytes: -1),
        throwsA(isA<ArgumentError>()),
      );
      await expectLater(
        printer.queryStatus(
          [0x10, 0x04, 0x01],
          timeout: const Duration(milliseconds: -1),
        ),
        throwsA(isA<ArgumentError>()),
      );
      await expectLater(
        printer.queryStatus(
          [0x10, 0x04, 0x01],
          grace: const Duration(milliseconds: -1),
        ),
        throwsA(isA<ArgumentError>()),
      );
      await expectLater(
        printer.queryStatus(
          [0x10, 0x04, 0x01],
          quietPeriod: const Duration(milliseconds: -1),
        ),
        throwsA(isA<ArgumentError>()),
      );

      // Nijedan od gornjih poziva nije smio promijeniti stanje -- sljedeci
      // ispravan upit radi normalno.
      final result = await printer.queryStatus(
        [0x10, 0x04, 0x01],
        maxBytes: 1,
        timeout: const Duration(seconds: 2),
      );

      expect(result, Uint8List.fromList([0x12]));
    });
  });
}
