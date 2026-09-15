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

  /// True ako je prethodni [queryStatus] istekao bez ijednog primljenog
  /// bajta -- printer mu jos moze odgovoriti KASNIJE (tipicno queued
  /// `GS r`), a taj zakasnjeli odgovor bi inace tiho zavrsio SLJEDECI,
  /// nepovezani upit. Cisti se cim neki upit dobije bar jedan bajt, i u
  /// [connect].
  bool _previousQueryUnanswered = false;

  /// True od pocetka [queryStatus] poziva (prije eventualnog cekanja na
  /// tisinu) do njegovog finally bloka -- koristi se da se preklapajuci
  /// pozivi odbiju. Za razliku od [_statusCompleter] (koji se postavlja tek
  /// NAKON cekanja na tisinu), ova zastavica pokriva CIJELI poziv, pa drugi
  /// queryStatus ne moze proci dok prvi jos ceka da linija utihne. Cisti se
  /// i u [connect] i u [disconnect].
  bool _queryInProgress = false;

  /// Monotono raste za svaki primljeni bajt, cak i kad [_trimIdleBuffer]
  /// skrati [_incomingBuffer] na [_idleBufferCap] -- [_drainUntilQuiet]
  /// mjeri tisinu po ovome, ne po duljini spremnika (koja moze stajati na
  /// stropu dok printer i dalje salje).
  int _totalBytesReceived = 0;

  /// Povecava se u [connect] i [disconnect] -- svaka (ponovna) uspostava
  /// ili prekid veze pocinje novu generaciju. [queryStatus] njome
  /// prepoznaje da je veza zamijenjena ili zatvorena dok je on cekao tisinu
  /// u [_drainUntilQuiet]: bez ove provjere bi upit koji je zapoceo PRIJE
  /// reconnecta, a jos ceka tisinu, mogao poslati zahtjev na NOVU vezu i
  /// preoteti stanje/timere upitu koji je u medjuvremenu vec zapocet na
  /// njoj.
  ///
  /// [connect] ga povecava SINKRONO, prije prvog `await`, i pamti svoju
  /// vrijednost lokalno -- tako dva [connect] poziva bez medjusobnog
  /// cekanja odmah dobiju razlicite generacije, pa raniji poziv, kad se
  /// probudi iz svog await-a, prepozna da je nadjacan i povuce se bez
  /// diranja stanja koje je noviji poziv u medjuvremenu preuzeo. [disconnect]
  /// ga povecava bez obzira ima li trenutno spojen socket, da ponisti i
  /// [connect] koji jos ceka na `Socket.connect`.
  int _connectionGeneration = 0;

  Socket get _socket => _socketOrNull!;

  int? get port => _port;
  String? get host => _host;
  PaperSize get paperSize => _paperSize;
  CapabilityProfile get profile => _profile;

  Future<PosPrintResult> connect(String host,
      {int port = 9100, Duration timeout = const Duration(seconds: 5)}) async {
    _host = host;
    _port = port;

    // Nova generacija -- vidi [_connectionGeneration]. Povecava se SINKRONO,
    // prije bilo kojeg `await` nize, da dva connect() poziva bez
    // medjusobnog cekanja odmah uhvate SVOJU, razlicitu generaciju prije
    // nego ijedan preda kontrolu event loopu. Bez toga bi oba poziva,
    // probudivsi se iz istog await-a, mislila da su "trenutni" i svaki bi
    // instalirao svoj listener -- zadnji bi prepisao polja, ali raniji
    // listener bi ostao ziv i njegovi dogadjaji (npr. odgovor sa STAROG
    // servera) mogli bi dovrsiti upit ili postaviti prekinuto stanje na
    // NOVOJ vezi.
    _connectionGeneration++;
    final myGeneration = _connectionGeneration;

    // Ako se connect() pozove iznova bez prethodnog disconnect() (npr.
    // reconnect logika pozivatelja, ili drugi paralelni connect() poziv),
    // stara pretplata i eventualni upit u tijeku ne smiju preziviti na novi
    // socket -- inace dogadjaj sa STAROG socketa (npr. zakasnjeli onDone)
    // moze dovrsiti upit koji ceka na NOVOM. Ovaj dio je namjerno sinkron i
    // idempotentan (izvrsava se prije prvog await-a): ako dva connect()
    // poziva trce jedan za drugim bez cekanja, prvi ovdje pociste sve stare
    // reference i postavi ih na null, pa drugi ovdje zatekne vec pociscene
    // vrijednosti i ne radi nista dvaput.
    final staleSubscription = _incomingSubscription;
    _incomingSubscription = null;
    final stalePending = _statusCompleter;
    if (stalePending != null && !stalePending.isCompleted) {
      stalePending.completeError(StateError(
          'queryStatus: connect() je pozvan iznova dok se cekao odgovor.'));
    }
    _statusCompleter = null;
    _brokenReason = null;
    _incomingBuffer.clear();
    _previousQueryUnanswered = false;
    _queryInProgress = false;

    // Stari socket se odvaja i unistava PRIJE Socket.connect nize -- ako
    // spojen printer dobije neuspjeli reconnect (Socket.connect dolje
    // baci), `_socketOrNull` ne smije i dalje pokazivati na staru vezu
    // ciju je pretplata upravo otkazana: queryStatus bi inace prosao
    // provjeru spojenosti i pisao u vezu s koje se odgovor vise ne moze
    // vidjeti, a i obican ispis bi gadjao napustenu vezu.
    final staleSocket = _socketOrNull;
    _socketOrNull = null;
    staleSocket?.destroy();

    await staleSubscription?.cancel();

    // Ako je u medjuvremenu (dok se cekao cancel() gore) zapocet NOVIJI
    // connect() poziv, on je vec uhvatio noviju generaciju gore, sinkrono,
    // pa je ovaj (stariji) poziv nadjacan -- povlaci se bez ikakve daljnje
    // izmjene stanja, da ne prepise ono sto je noviji poziv u medjuvremenu
    // vec postavio.
    if (_connectionGeneration != myGeneration) {
      return PosPrintResult.timeout;
    }

    try {
      final socket = await Socket.connect(host, port, timeout: timeout);

      // Isto kao gore, ali nakon Socket.connect -- ako se generacija u
      // medjuvremenu promijenila (noviji connect() ili disconnect() dok se
      // cekalo na TCP handshake), ovaj socket vise nije zeljen. Unisti se
      // odmah i ne diraj nikakvo stanje -- ne instalirati listener koji bi
      // pripadao tudjoj generaciji.
      if (_connectionGeneration != myGeneration) {
        socket.destroy();
        return PosPrintResult.timeout;
      }

      _socketOrNull = socket;
      _brokenReason = null;
      _incomingBuffer.clear();
      // Otvara se tocno jednom, ovdje -- `Socket` je single-subscription
      // stream pa druga pretplata na isti socket baca gresku. Svaki
      // callback provjerava generaciju PRIJE bilo cega drugog, tako da
      // dogadjaji sa socketa zastarjele generacije (npr. ako se u
      // medjuvremenu vec pozvao novi connect()/disconnect()) nikad ne
      // diraju tekuce stanje.
      _incomingSubscription = socket.listen(
        (Uint8List data) {
          if (_connectionGeneration != myGeneration) return;
          _onIncomingData(data);
        },
        onError: (Object error) {
          if (_connectionGeneration != myGeneration) return;
          _onIncomingError(error);
        },
        onDone: () {
          if (_connectionGeneration != myGeneration) return;
          _onIncomingDone();
        },
      );
      socket.add(_generator.reset());
      // Metoda je `async`, pa se vrijednost vraca izravno. Omotavanje u
      // `Future.value` unutar `try` bloka pali `unawaited_return_in_try_block`
      // jer takav Future izmice `catch`-u; ovdje je bio bezopasan (vec
      // dovrsen), ali izravan povratak je i jednostavniji i tocan.
      return PosPrintResult.success;
    } catch (e) {
      // Ako je generacija u medjuvremenu vec zamijenjena, stanje pripada
      // novijem pozivu -- ne dirati ga.
      if (_connectionGeneration == myGeneration) {
        _socketOrNull = null;
      }
      return PosPrintResult.timeout;
    }
  }

  void _onIncomingData(Uint8List data) {
    // Prije bilo kakvog skracivanja -- vidi [_totalBytesReceived].
    _totalBytesReceived += data.length;
    _incomingBuffer.add(data);

    final completer = _statusCompleter;
    if (completer == null || completer.isCompleted) {
      // Nijedan queryStatus ne ceka ovo -- vjerojatno ASB paket koji
      // printer salje sam od sebe. Ne raste bez granice.
      _trimIdleBuffer();
      return;
    }

    // Prvi (ili sljedeci) bajt je stigao, pa `timeout` rok za prvi bajt
    // vise ne vrijedi -- od sada odlucuje samo jos [_statusGrace]. Printer
    // je ocito ziv i odgovara, pa eventualna zabiljeska o prethodnom
    // neodgovorenom upitu vise nije relevantna.
    _statusDeadlineTimer?.cancel();
    _statusDeadlineTimer = null;
    _previousQueryUnanswered = false;

    if (_incomingBuffer.length >= _statusMaxBytes) {
      _statusGraceTimer?.cancel();
      _statusGraceTimer = null;
      // Jedan TCP dogadjaj zna donijeti vise od maxBytes odjednom (npr. jos
      // koji bajt zalijepljen uz odgovor) -- visak se odbacuje, jer
      // pozivatelj trazi tocno maxBytes, ne "barem maxBytes".
      final bytes = _incomingBuffer.toBytes();
      completer
          .complete(Uint8List.fromList(bytes.sublist(0, _statusMaxBytes)));
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
  /// If a [queryStatus] call is still waiting for an answer, it is
  /// completed with an error here -- otherwise it would silently see an
  /// empty result, indistinguishable from a live printer staying quiet.
  ///
  /// [delayMs]: milliseconds to wait after destroying the socket
  Future<void> disconnect({int? delayMs}) async {
    // Nova generacija -- vidi [_connectionGeneration]. Povecava se OVDJE,
    // bez obzira je li trenutno nesto spojeno -- tako disconnect() koji
    // stigne dok [connect] jos ceka `Socket.connect` (i `_socketOrNull` je
    // jos uvijek null, jer connect() stari socket odvaja PRIJE tog await-a)
    // svejedno ponisti taj connect(): kad se on probudi, prepoznat ce
    // promijenjenu generaciju, unistiti tek uspostavljeni socket i vratiti
    // timeout umjesto da ostavi vezu otvorenom ispod ove diskonekcije.
    _connectionGeneration++;

    final socket = _socketOrNull;

    // Never connected, or already disconnected: nothing to flush or wait for.
    if (socket == null) return;

    _socketOrNull = null;

    await _incomingSubscription?.cancel();
    _incomingSubscription = null;

    // Otkazivanje pretplate ne zove onDone, pa bi aktivni upit inace tiho
    // dobio prazan odgovor umjesto da vidi da mu je veza ugasena ispod
    // njega -- pukla ili namjerno zatvorena veza nije tisina.
    final pendingStatus = _statusCompleter;
    if (pendingStatus != null && !pendingStatus.isCompleted) {
      pendingStatus.completeError(StateError(
          'queryStatus: disconnect() je pozvan dok se cekao odgovor.'));
    }
    _queryInProgress = false;

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
  /// ili `GS r n` za queued status).
  ///
  /// Ako je PRETHODNI poziv istekao bez ijednog primljenog bajta, printer mu
  /// jos moze odgovoriti KASNIJE -- ESC/POS odgovor ne nosi nikakvu oznaku
  /// upita, pa bi taj zakasnjeli odgovor inace tiho zavrsio OVAJ, novi upit.
  /// Taj se slucaj tada NE rjesava obicnim ciscenjem medjuspremnika, nego se
  /// ceka [quietPeriod] tisine na liniji (uz gornju granicu od 1 s ukupnog
  /// cekanja), odbacujuci sve sto u medjuvremenu stigne. Ovo je samo
  /// UBLAZAVANJE, ne stvarno sparivanje odgovora s upitom -- transport nema
  /// dovoljno informacija za to (ESC/POS odgovor ne nosi oznaku upita), pa
  /// stvarno sparivanje (npr. po ocekivanim bitovima odgovora) mora raditi
  /// pozivatelj.
  ///
  /// [timeout] je rok za CIJELO cekanje prvog bajta, UKLJUCUJUCI i samo
  /// slanje -- printer koji je mrtav ili mu je pun TCP prozor moze uzrokovati
  /// da samo slanje (`flush()`) nikad ne zavrsi, a upravo takvog printera
  /// zelimo prijaviti kao "ne odgovara" umjesto da poziv visi zauvijek. Cim
  /// prvi bajt stigne, `timeout` prestaje vrijediti i pocinje [grace]: kratak
  /// razmak koji se restarta na svaki sljedeci bajt, tako da se visebajtni
  /// odgovor priceka cijeli bez cekanja punog `timeout`-a. Cekanje zavrsava
  /// cim se skupi [maxBytes] bajtova (visak iz istog TCP dogadjaja se
  /// odbacuje), ili cim od zadnjeg bajta protekne [grace] -- sto prije
  /// nastupi. Vraca ono sto je do tada skupljeno.
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
  /// Baca gresku ako veze uopce nema, ako je veza pukla (`onError`, `onDone`
  /// ili `disconnect()`) prije ili tijekom cekanja -- pozivatelj mora moci
  /// razlikovati tisinu zivog printera od mrtve veze -- ili ako je drugi
  /// poziv [queryStatus] vec u tijeku (pozivi se ne smiju preklapati).
  ///
  /// Baca `ArgumentError` -- bez da isprazni bilo kakvo stanje ili posalje
  /// ijedan bajt -- ako je [request] prazan, ako [maxBytes] nije pozitivan,
  /// ili ako je bilo koji od [timeout]/[grace]/[quietPeriod] negativan.
  Future<Uint8List> queryStatus(
    final List<int> request, {
    final Duration timeout = const Duration(milliseconds: 600),
    final Duration grace = const Duration(milliseconds: 50),
    final Duration quietPeriod = const Duration(milliseconds: 150),
    final int maxBytes = 16,
  }) async {
    // Provjera argumenata ide PRIJE bilo kakvog postavljanja stanja -- npr.
    // negativan maxBytes bi kasnije bacio unutar _onIncomingData (kroz
    // sublist), sto ne prolazi kroz completer i ostavlja queryStatus da
    // visi zauvijek jer je rok vec otkazan.
    if (request.isEmpty) {
      throw ArgumentError.value(request, 'request', 'ne smije biti prazan.');
    }
    if (maxBytes <= 0) {
      throw ArgumentError.value(maxBytes, 'maxBytes', 'mora biti pozitivan.');
    }
    if (timeout.isNegative) {
      throw ArgumentError.value(timeout, 'timeout', 'ne smije biti negativan.');
    }
    if (grace.isNegative) {
      throw ArgumentError.value(grace, 'grace', 'ne smije biti negativan.');
    }
    if (quietPeriod.isNegative) {
      throw ArgumentError.value(
          quietPeriod, 'quietPeriod', 'ne smije biti negativan.');
    }

    if (_socketOrNull == null) {
      throw StateError(
          'queryStatus: printer nije povezan (connect nije uspio, ili je '
          'vec pozvan disconnect).');
    }

    if (_brokenReason != null) {
      throw _brokenReason!;
    }

    // Zastavica pokriva CIJELI poziv, ukljucujuci i eventualno cekanje na
    // tisinu nize -- `_statusCompleter` se postavlja tek NAKON tog cekanja,
    // pa provjera preklapanja preko njega ostavlja prozor u kojem bi drugi
    // poziv prosao dok prvi jos ceka tisinu.
    if (_queryInProgress) {
      throw StateError(
          'queryStatus: prethodni upit jos ceka odgovor -- pozivi se ne '
          'smiju preklapati.');
    }
    _queryInProgress = true;
    // Vidi [_connectionGeneration]: ako se promijeni dok cekamo tisinu
    // nize, veza je zamijenjena (novi connect()) ili zatvorena
    // (disconnect()) ispod ovog poziva.
    final myGeneration = _connectionGeneration;

    try {
      if (_previousQueryUnanswered) {
        await _drainUntilQuiet(quietPeriod, const Duration(seconds: 1));

        if (_connectionGeneration != myGeneration) {
          throw StateError(
              'queryStatus: veza je zamijenjena ili zatvorena dok se '
              'cekalo da linija utihne.');
        }
        if (_brokenReason != null) {
          throw _brokenReason!;
        }
      }

      // Socket se uzima TEK ovdje -- nakon eventualnog cekanja na tisinu
      // gore -- da se upit posalje na TRENUTNU vezu, a ne na onu uhvacenu
      // prije cekanja (koja je u medjuvremenu mogla biti zamijenjena).
      final socket = _socketOrNull;
      if (socket == null) {
        throw StateError(
            'queryStatus: veza je zatvorena dok se cekalo da linija '
            'utihne.');
      }

      _incomingBuffer.clear();
      final completer = Completer<Uint8List>();
      _statusCompleter = completer;
      _statusMaxBytes = maxBytes;
      _statusGrace = grace;

      // Rok pokriva CIJELO cekanje, ukljucujuci i samo slanje -- vidi
      // dokumentaciju gore. Naoruzava se PRIJE slanja; `_onIncomingData` ga
      // otkazuje cim stigne prvi bajt.
      _statusDeadlineTimer = Timer(timeout, () {
        if (!completer.isCompleted) {
          _previousQueryUnanswered = true;
          completer.complete(Uint8List.fromList(_incomingBuffer.toBytes()));
        }
      });

      try {
        socket.add(request);
        // `flush()` moze visjeti ako printer ne cita (pun TCP prozor) -- rok
        // gore to vec pokriva, pa se ne ceka izravno (`await`) ovdje; ako
        // ipak BACI (npr. veza je vec pukla), ta se greska prosljedjuje kroz
        // completer, osim ako je on vec zavrsio na neki drugi nacin.
        unawaited(flush().then((_) {}, onError: (Object e, StackTrace st) {
          if (!completer.isCompleted) {
            completer.completeError(e, st);
          }
        }));

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
    } finally {
      // Samo ako je generacija ista kao na pocetku -- inace bi ovaj (stari)
      // poziv obrisao zastavicu upita koji je u medjuvremenu vec zapocet
      // na NOVOJ vezi.
      if (_connectionGeneration == myGeneration) {
        _queryInProgress = false;
      }
    }
  }

  /// Ceka da linija utihne prije novog upita -- vidi [queryStatus]. Ceka
  /// [quietPeriod] bez ikakvog novog bajta, ili do isteka [cap] ukupno, sto
  /// prije nastupi; sve primljeno u medjuvremenu se odbacuje.
  ///
  /// Tisina se mjeri preko [_totalBytesReceived], ne preko duljine
  /// [_incomingBuffer] -- ona [_trimIdleBuffer] drzi na [_idleBufferCap] dok
  /// nijedan upit ne ceka, pa bi printer koji i dalje salje (spremnik vec
  /// pun) izgledao lazno tiho.
  Future<void> _drainUntilQuiet(Duration quietPeriod, Duration cap) async {
    final stopwatch = Stopwatch()..start();
    var lastCount = _totalBytesReceived;

    while (stopwatch.elapsed < cap) {
      final remaining = cap - stopwatch.elapsed;
      await Future<void>.delayed(
          remaining < quietPeriod ? remaining : quietPeriod);

      if (_totalBytesReceived == lastCount) break;
      lastCount = _totalBytesReceived;
    }

    _incomingBuffer.clear();
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
