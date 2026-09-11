/*
 * esc_pos_printer
 * Created by Andrey Ushakov
 * 
 * Copyright (c) 2019-2020. All rights reserved.
 * See LICENSE for distribution and usage details.
 */

import 'dart:async';
import 'dart:io';
import 'dart:typed_data' show BytesBuilder, Uint8List;
import 'package:esc_pos_utils/esc_pos_utils.dart';
import 'package:image/image.dart';
import './enums.dart';

/// Network Printer
class NetworkPrinter {
  NetworkPrinter(this._paperSize, this._profile, {int spaceBetweenRows = 5}) {
    _generator =
        Generator(paperSize, profile, spaceBetweenRows: spaceBetweenRows);
  }

  final PaperSize _paperSize;
  final CapabilityProfile _profile;
  String? _host;
  int? _port;
  late Generator _generator;
  /// Null until [connect] succeeds, and again after [disconnect].
  ///
  /// Callers wrap printing in `try`/`finally` and disconnect on every path,
  /// including the one where `connect` returned [PosPrintResult.timeout]. With
  /// a `late` field that teardown threw a LateInitializationError, which hid
  /// the real failure behind a second, unrelated one.
  Socket? _socketOrNull;

  /// Pretplata na dolazne bajtove sa socketa. `Socket` je single-subscription
  /// stream pa se pretplacuje tocno jednom, u [connect]; [disconnect] je
  /// otkazuje.
  StreamSubscription<Uint8List>? _incomingSubscription;

  /// Medjuspremnik bajtova primljenih otkad je [queryStatus] zadnji put
  /// ispraznio spremnik.
  final BytesBuilder _incomingBuffer = BytesBuilder();

  /// Completer koji ceka odgovor za trenutni [queryStatus] poziv, ili null
  /// ako se trenutno nista ne ceka.
  Completer<Uint8List>? _statusCompleter;

  /// Koliko bajtova [_statusCompleter] ceka prije nego se sam dovrsi.
  int _statusMaxBytes = 0;

  /// Koliko se jos ceka nakon SVAKOG novog bajta prije nego se
  /// [_statusCompleter] dovrsi -- vidi [queryStatus].
  Duration _statusGrace = const Duration(milliseconds: 50);

  /// Rok za PRVI bajt tekuceg [queryStatus] poziva. Otkazuje se cim prvi
  /// bajt stigne, jer od tog trenutka vise ne vrijedi `timeout` nego
  /// [_statusGraceTimer].
  Timer? _statusDeadlineTimer;

  /// Kratki timer koji se restarta na svaki novi bajt dok se ceka odgovor;
  /// dovrsava [_statusCompleter] cim protekne [_statusGrace] od zadnjeg
  /// primljenog bajta -- vidi [queryStatus].
  Timer? _statusGraceTimer;

  /// Gornja granica [_incomingBuffer] dok nijedan [queryStatus] ne ceka
  /// odgovor -- vidi [_trimIdleBuffer].
  static const int _idleBufferCap = 256;

  /// Postavljeno cim `onError` ili `onDone` javi da je veza pukla, i vise se
  /// ne cisti -- veza se ionako mora ponovno uspostaviti kroz [connect].
  /// Koristi ga [queryStatus] da tisinu zivog printera razlikuje od mrtve
  /// veze.
  Object? _brokenReason;

  Socket get _socket => _socketOrNull!;

  int? get port => _port;
  String? get host => _host;
  PaperSize get paperSize => _paperSize;
  CapabilityProfile get profile => _profile;

  Future<PosPrintResult> connect(String host,
      {int port = 9100, Duration timeout = const Duration(seconds: 5)}) async {
    _host = host;
    _port = port;
    try {
      _socketOrNull = await Socket.connect(host, port, timeout: timeout);
      _brokenReason = null;
      _incomingBuffer.clear();
      // Otvara se tocno jednom, ovdje -- `Socket` je single-subscription
      // stream pa druga pretplata na isti socket baca gresku.
      _incomingSubscription = _socket.listen(
        _onIncomingData,
        onError: _onIncomingError,
        onDone: _onIncomingDone,
      );
      _socket.add(_generator.reset());
      // Metoda je `async`, pa se vrijednost vraca izravno. Omotavanje u
      // `Future.value` unutar `try` bloka pali `unawaited_return_in_try_block`
      // jer takav Future izmice `catch`-u; ovdje je bio bezopasan (vec
      // dovrsen), ali izravan povratak je i jednostavniji i tocan.
      return PosPrintResult.success;
    } catch (e) {
      return PosPrintResult.timeout;
    }
  }

  void _onIncomingData(Uint8List data) {
    _incomingBuffer.add(data);

    final completer = _statusCompleter;
    if (completer == null || completer.isCompleted) {
      // Nijedan queryStatus ne ceka ovo -- vjerojatno ASB paket koji
      // printer salje sam od sebe. Ne raste bez granice.
      _trimIdleBuffer();
      return;
    }

    // Prvi (ili sljedeci) bajt je stigao, pa `timeout` rok za prvi bajt
    // vise ne vrijedi -- od sada odlucuje samo jos [_statusGrace].
    _statusDeadlineTimer?.cancel();
    _statusDeadlineTimer = null;

    if (_incomingBuffer.length >= _statusMaxBytes) {
      _statusGraceTimer?.cancel();
      _statusGraceTimer = null;
      completer.complete(Uint8List.fromList(_incomingBuffer.toBytes()));
      return;
    }

    // Restarta se na svaki novi bajt, da visebajtni odgovor stigne cijeli
    // prije nego se completer dovrsi.
    _statusGraceTimer?.cancel();
    _statusGraceTimer = Timer(_statusGrace, () {
      if (!completer.isCompleted) {
        completer.complete(Uint8List.fromList(_incomingBuffer.toBytes()));
      }
    });
  }

  /// Bez ogranicenja bi dolazni bajtovi primljeni dok nijedan [queryStatus]
  /// ne ceka odgovor (npr. ASB paketi koje printer salje sam od sebe tokom
  /// cijelog dana ispisivanja) beskonacno rasli u memoriji. [queryStatus]
  /// ionako isprazni spremnik prije svakog upita, pa se stariji ostaci ne
  /// trebaju cuvati -- zadrzava se samo zadnjih [_idleBufferCap] bajtova.
  void _trimIdleBuffer() {
    if (_incomingBuffer.length <= _idleBufferCap) return;

    final tail = _incomingBuffer
        .toBytes()
        .sublist(_incomingBuffer.length - _idleBufferCap);
    _incomingBuffer.clear();
    _incomingBuffer.add(tail);
  }

  void _onIncomingError(Object error) {
    _brokenReason = error;
    final completer = _statusCompleter;
    if (completer != null && !completer.isCompleted) {
      completer.completeError(error);
    }
  }

  void _onIncomingDone() {
    _brokenReason ??=
        const SocketException('Veza s printerom je zatvorena (onDone).');
    final completer = _statusCompleter;
    if (completer != null && !completer.isCompleted) {
      completer.completeError(_brokenReason!);
    }
  }

  /// Waits until everything written so far has reached the socket.
  ///
  /// Throws if the connection broke in the meantime, so the caller can report
  /// a failed print instead of assuming the receipt arrived. [disconnect]
  /// swallows the very same error on purpose — tearing a connection down must
  /// not fail — which makes this the only place where it can surface.
  ///
  /// Does nothing when there is no connection; that failure was already
  /// reported by [connect].
  Future<void> flush() async {
    final socket = _socketOrNull;

    if (socket == null) return;

    await socket.flush();
  }

  /// Closes the connection to the printer.
  ///
  /// Waits for everything already written to reach the socket before tearing
  /// it down. `Socket.destroy()` waits for nothing, so without the flush a
  /// long receipt was silently truncated whenever the printer read slowly —
  /// measured on a ~1 MB ticket against a receiver that paused for 500 ms,
  /// only half of it arrived. The old `delayMs` could not help: it ran
  /// *after* `destroy()`, when the unwritten bytes were already gone.
  ///
  /// [delayMs]: milliseconds to wait after destroying the socket
  Future<void> disconnect({int? delayMs}) async {
    final socket = _socketOrNull;

    // Never connected, or already disconnected: nothing to flush or wait for.
    if (socket == null) return;

    _socketOrNull = null;

    await _incomingSubscription?.cancel();
    _incomingSubscription = null;

    try {
      await socket.flush();
    } catch (_) {
      // The connection is already broken; there is nothing left to flush.
    }

    socket.destroy();

    if (delayMs != null) {
      await Future.delayed(Duration(milliseconds: delayMs), () => null);
    }
  }

  /// Salje upit statusa printeru i ceka odgovor na vec otvorenoj vezi.
  ///
  /// [request] su sirovi bajtovi upita (npr. `DLE EOT n` za real-time status,
  /// ili `GS r n` za queued status). Prije slanja isprazni se interni
  /// medjuspremnik primljenih bajtova, zatim se salje [request] i ceka
  /// `flush()`.
  ///
  /// [timeout] je rok SAMO za PRVI bajt odgovora -- ako do njega nista ne
  /// stigne u tom roku, vraca se prazan rezultat (vidi nize). Cim prvi bajt
  /// stigne, `timeout` prestaje vrijediti i pocinje [grace]: kratak razmak
  /// koji se restarta na svaki sljedeci bajt, tako da se visebajtni odgovor
  /// priceka cijeli bez cekanja punog `timeout`-a. Cekanje zavrsava cim se
  /// skupi [maxBytes] bajtova, ili cim od zadnjeg bajta protekne [grace] --
  /// sto prije nastupi. Vraca ono sto je do tada skupljeno.
  ///
  /// PRAZAN rezultat je legitiman odgovor -- znaci da printer unutar
  /// [timeout]-a nije nista poslao -- i NIJE greska.
  ///
  /// Zadani [timeout] od 600 ms odgovara `DLE EOT`: printer na njega
  /// odgovara odmah, iz prekidne rutine, pa je i par desetaka milisekundi
  /// dovoljno da se prepozna "nema odgovora". Za `GS r` (queued status)
  /// pozivatelj MORA podici [timeout] na nekoliko sekundi -- taj odgovor
  /// stize tek kad printer obradi sve sto je vec u njegovom bufferu ispred
  /// njega, pa kratak timeout ovdje redovito pogresno prijavi da printer ne
  /// odgovara. Zadani [grace] od 50 ms vrijedi za oba slucaja podjednako,
  /// jer se broji tek nakon sto je printer vec pocelo odgovarati.
  ///
  /// Baca gresku ako veze uopce nema, ako je veza pukla (`onError` ili
  /// `onDone`) prije ili tijekom cekanja -- pozivatelj mora moci razlikovati
  /// tisinu zivog printera od mrtve veze -- ili ako je drugi poziv
  /// [queryStatus] vec u tijeku (pozivi se ne smiju preklapati).
  Future<Uint8List> queryStatus(
    final List<int> request, {
    final Duration timeout = const Duration(milliseconds: 600),
    final Duration grace = const Duration(milliseconds: 50),
    final int maxBytes = 16,
  }) async {
    final socket = _socketOrNull;
    if (socket == null) {
      throw StateError(
          'queryStatus: printer nije povezan (connect nije uspio, ili je '
          'vec pozvan disconnect).');
    }

    if (_brokenReason != null) {
      throw _brokenReason!;
    }

    if (_statusCompleter != null && !_statusCompleter!.isCompleted) {
      throw StateError(
          'queryStatus: prethodni upit jos ceka odgovor -- pozivi se ne '
          'smiju preklapati.');
    }

    _incomingBuffer.clear();
    final completer = Completer<Uint8List>();
    _statusCompleter = completer;
    _statusMaxBytes = maxBytes;
    _statusGrace = grace;

    socket.add(request);
    await flush();

    // Rok za PRVI bajt; nakon njega preuzima [_statusGraceTimer], pokrenut
    // iz [_onIncomingData].
    _statusDeadlineTimer = Timer(timeout, () {
      if (!completer.isCompleted) {
        completer.complete(Uint8List.fromList(_incomingBuffer.toBytes()));
      }
    });

    try {
      return await completer.future;
    } finally {
      _statusDeadlineTimer?.cancel();
      _statusDeadlineTimer = null;
      _statusGraceTimer?.cancel();
      _statusGraceTimer = null;
      if (identical(_statusCompleter, completer)) {
        _statusCompleter = null;
      }
    }
  }

  // ************************ Printer Commands ************************
  void reset() {
    _socket.add(_generator.reset());
  }

  void text(
    String text, {
    PosStyles styles = const PosStyles(),
    int linesAfter = 0,
    bool containsChinese = false,
    int? maxCharsPerLine,
  }) {
    _socket.add(_generator.text(text,
        styles: styles,
        linesAfter: linesAfter,
        containsChinese: containsChinese,
        maxCharsPerLine: maxCharsPerLine));
  }

  void setGlobalCodeTable(String codeTable) {
    _socket.add(_generator.setGlobalCodeTable(codeTable));
  }

  void setGlobalFont(PosFontType font, {int? maxCharsPerLine}) {
    _socket
        .add(_generator.setGlobalFont(font, maxCharsPerLine: maxCharsPerLine));
  }

  void setStyles(PosStyles styles, {bool isKanji = false}) {
    _socket.add(_generator.setStyles(styles, isKanji: isKanji));
  }

  void rawBytes(List<int> cmd, {bool isKanji = false}) {
    _socket.add(_generator.rawBytes(cmd, isKanji: isKanji));
  }

  void emptyLines(int n) {
    _socket.add(_generator.emptyLines(n));
  }

  void feed(int n) {
    _socket.add(_generator.feed(n));
  }

  void cut({PosCutMode mode = PosCutMode.full}) {
    _socket.add(_generator.cut(mode: mode));
  }

  void printCodeTable({String? codeTable}) {
    _socket.add(_generator.printCodeTable(codeTable: codeTable));
  }

  void beep({int n = 3, PosBeepDuration duration = PosBeepDuration.beep450ms}) {
    _socket.add(_generator.beep(n: n, duration: duration));
  }

  void reverseFeed(int n) {
    _socket.add(_generator.reverseFeed(n));
  }

  void row(List<PosColumn> cols) {
    _socket.add(_generator.row(cols));
  }

  void image(Image imgSrc, {PosAlign align = PosAlign.center}) {
    _socket.add(_generator.image(imgSrc, align: align));
  }

  void imageRaster(
    Image image, {
    PosAlign align = PosAlign.center,
    bool highDensityHorizontal = true,
    bool highDensityVertical = true,
    PosImageFn imageFn = PosImageFn.bitImageRaster,
  }) {
    _socket.add(_generator.imageRaster(
      image,
      align: align,
      highDensityHorizontal: highDensityHorizontal,
      highDensityVertical: highDensityVertical,
      imageFn: imageFn,
    ));
  }

  void barcode(
    Barcode barcode, {
    int? width,
    int? height,
    BarcodeFont? font,
    BarcodeText textPos = BarcodeText.below,
    PosAlign align = PosAlign.center,
  }) {
    _socket.add(_generator.barcode(
      barcode,
      width: width,
      height: height,
      font: font,
      textPos: textPos,
      align: align,
    ));
  }

  void qrcode(
    String text, {
    PosAlign align = PosAlign.center,
    QRSize size = QRSize.Size4,
    QRCorrection cor = QRCorrection.L,
  }) {
    _socket.add(_generator.qrcode(text, align: align, size: size, cor: cor));
  }

  void drawer({PosDrawer pin = PosDrawer.pin2}) {
    _socket.add(_generator.drawer(pin: pin));
  }

  void hr({String ch = '-', int? len, int linesAfter = 0}) {
    _socket.add(_generator.hr(ch: ch, linesAfter: linesAfter));
  }

  void textEncoded(
    Uint8List textBytes, {
    PosStyles styles = const PosStyles(),
    int linesAfter = 0,
    int? maxCharsPerLine,
  }) {
    _socket.add(_generator.textEncoded(
      textBytes,
      styles: styles,
      linesAfter: linesAfter,
      maxCharsPerLine: maxCharsPerLine,
    ));
  }
  // ************************ (end) Printer Commands ************************
}
