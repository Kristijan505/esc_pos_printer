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

  group('NetworkPrinter.disconnect', () {
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
}
