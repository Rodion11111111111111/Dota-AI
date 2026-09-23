import 'dart:async';
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  final nastroyki = await NastroykiServera.zagruzit();
  if (nastroyki.klyuchGemini.isEmpty) {
    stderr.writeln(
      'GEMINI_API_KEY не найден. Создайте файл .env рядом с .env.example.',
    );
    exitCode = 1;
    return;
  }

  final server = await HttpServer.bind(nastroyki.host, nastroyki.port);
  stdout.writeln(
    'Локальный сервер Dota AI запущен: http://${nastroyki.host}:${nastroyki.port}',
  );
  stdout.writeln('Он принимает запросы только с этого компьютера.');
  final klientGemini = KlientGemini(nastroyki);
  final ogranichitelZaprosov = OgranichitelZaprosov();

  await for (final zapros in server) {
    unawaited(
      _obrabotatZapros(zapros, klientGemini, nastroyki, ogranichitelZaprosov),
    );
  }
}

Future<void> _obrabotatZapros(
  HttpRequest zapros,
  KlientGemini klientGemini,
  NastroykiServera nastroyki,
  OgranichitelZaprosov ogranichitelZaprosov,
) async {
  try {
    if (zapros.method == 'GET' && zapros.uri.path == '/health') {
      return await _otpravitJson(zapros.response, HttpStatus.ok, {
        'status': 'ok',
      });
    }
    if (zapros.method != 'POST' || zapros.uri.path != '/api/chat') {
      return await _otpravitJson(zapros.response, HttpStatus.notFound, {
        'error': 'Маршрут не найден.',
      });
    }
    if (!nastroyki.dostupRazreshen(zapros)) {
      return await _otpravitJson(zapros.response, HttpStatus.unauthorized, {
        'error': 'Для этого сервера требуется ключ доступа приложения.',
      });
    }
    if (!ogranichitelZaprosov.razreshit(zapros)) {
      return await _otpravitJson(zapros.response, HttpStatus.tooManyRequests, {
        'error': 'Слишком много запросов. Попробуйте через минуту.',
      });
    }
    if ((zapros.contentLength) > 65536) {
      return await _otpravitJson(
        zapros.response,
        HttpStatus.requestEntityTooLarge,
        {'error': 'Слишком большой запрос.'},
      );
    }

    final telo = await utf8.decoder.bind(zapros).join();
    dynamic dannye;
    try {
      dannye = jsonDecode(telo);
    } on FormatException {
      return await _otpravitJson(zapros.response, HttpStatus.badRequest, {
        'error': 'Приложение отправило неверный JSON.',
      });
    }
    if (dannye is! Map<String, dynamic>) {
      return await _otpravitJson(zapros.response, HttpStatus.badRequest, {
        'error': 'Неверный формат запроса.',
      });
    }
    final soobshcheniya = dannye['messages'];
    if (soobshcheniya is! List) {
      return await _otpravitJson(zapros.response, HttpStatus.badRequest, {
        'error': 'Не переданы сообщения.',
      });
    }

    final otvet = await _poluchitOtvetSPovtorom(klientGemini, soobshcheniya);
    return await _otpravitJson(zapros.response, HttpStatus.ok, {'text': otvet});
  } on OslushivanieKlienta catch (oshibka) {
    return _otpravitJson(zapros.response, oshibka.kod, {
      'error': oshibka.tekst,
    });
  } on FormatException {
    return _otpravitJson(zapros.response, HttpStatus.badGateway, {
      'error': 'Gemini вернул ответ в неизвестном формате.',
    });
  } on SocketException {
    return _otpravitJson(zapros.response, HttpStatus.badGateway, {
      'error': 'Нет соединения с сервисом Gemini.',
    });
  } catch (_) {
    return _otpravitJson(zapros.response, HttpStatus.internalServerError, {
      'error': 'Не удалось обработать запрос к Gemini.',
    });
  }
}

Future<String> _poluchitOtvetSPovtorom(
  KlientGemini klientGemini,
  List<dynamic> soobshcheniya,
) async {
  const zaderzhki = [Duration(seconds: 2), Duration(seconds: 5)];
  for (var popytka = 0; popytka <= zaderzhki.length; popytka++) {
    try {
      return await klientGemini.poluchitOtvet(soobshcheniya);
    } on OslushivanieKlienta catch (oshibka) {
      final vremennayaOshibka = const {
        HttpStatus.tooManyRequests,
        HttpStatus.internalServerError,
        HttpStatus.badGateway,
        HttpStatus.serviceUnavailable,
        HttpStatus.gatewayTimeout,
      }.contains(oshibka.kod);
      if (!vremennayaOshibka || popytka == zaderzhki.length) rethrow;
      await Future<void>.delayed(zaderzhki[popytka]);
    } on SocketException {
      if (popytka == zaderzhki.length) rethrow;
      await Future<void>.delayed(zaderzhki[popytka]);
    } on TimeoutException {
      if (popytka == zaderzhki.length) rethrow;
      await Future<void>.delayed(zaderzhki[popytka]);
    }
  }
  throw StateError('Цикл повторных попыток завершился некорректно.');
}

Future<void> _otpravitJson(
  HttpResponse otvet,
  int kod,
  Map<String, dynamic> dannye,
) async {
  otvet.statusCode = kod;
  otvet.headers.contentType = ContentType.json;
  otvet.write(jsonEncode(dannye));
  await otvet.close();
}

class OgranichitelZaprosov {
  static const _okno = Duration(minutes: 1);
  static const _maksimumZaprosov = 12;
  final Map<String, List<DateTime>> _zaprosy = {};

  bool razreshit(HttpRequest zapros) {
    final adres = zapros.connectionInfo?.remoteAddress.address ?? 'neizvestnyi';
    final seichas = DateTime.now();
    final tekushchie = _zaprosy.putIfAbsent(adres, () => []);
    tekushchie.removeWhere((vremya) => seichas.difference(vremya) > _okno);
    if (tekushchie.length >= _maksimumZaprosov) return false;
    tekushchie.add(seichas);
    return true;
  }
}

class NastroykiServera {
  const NastroykiServera({
    required this.klyuchGemini,
    required this.klyuchDostupa,
    required this.modelGemini,
    required this.host,
    required this.port,
  });

  final String klyuchGemini;
  final String klyuchDostupa;
  final String modelGemini;
  final String host;
  final int port;

  static Future<NastroykiServera> zagruzit() async {
    final peremennye = await _prochitatEnv(File('.env'));
    final okruzhenie = Platform.environment;
    final model =
        okruzhenie['GEMINI_MODEL'] ??
        peremennye['GEMINI_MODEL'] ??
        'gemini-2.5-flash';
    if (!RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(model)) {
      throw ArgumentError('GEMINI_MODEL содержит недопустимые символы.');
    }
    return NastroykiServera(
      klyuchGemini:
          okruzhenie['GEMINI_API_KEY'] ?? peremennye['GEMINI_API_KEY'] ?? '',
      klyuchDostupa:
          okruzhenie['DOTA_AI_ACCESS_KEY'] ??
          peremennye['DOTA_AI_ACCESS_KEY'] ??
          '',
      modelGemini: model,
      host: okruzhenie['HOST'] ?? peremennye['HOST'] ?? '0.0.0.0',
      port:
          int.tryParse(okruzhenie['PORT'] ?? peremennye['PORT'] ?? '') ?? 8080,
    );
  }

  bool dostupRazreshen(HttpRequest zapros) {
    if (klyuchDostupa.isEmpty) return true;
    return zapros.headers.value('x-dota-ai-access-key') == klyuchDostupa;
  }

  static Future<Map<String, String>> _prochitatEnv(File fayl) async {
    if (!await fayl.exists()) return {};
    final stroki = await fayl.readAsLines();
    final rezultat = <String, String>{};
    for (final stroka in stroki) {
      final ochishchennaya = stroka.trim();
      if (ochishchennaya.isEmpty || ochishchennaya.startsWith('#')) continue;
      final razdelitel = ochishchennaya.indexOf('=');
      if (razdelitel < 1) continue;
      rezultat[ochishchennaya.substring(0, razdelitel).trim()] = ochishchennaya
          .substring(razdelitel + 1)
          .trim();
    }
    return rezultat;
  }
}

class KlientGemini {
  KlientGemini(this._nastroyki);

  final NastroykiServera _nastroyki;
  final HttpClient _klient = HttpClient();

  Future<String> poluchitOtvet(List<dynamic> vhodyashchieSoobshcheniya) async {
    final soobshcheniya = _podgotovitIstoriyu(vhodyashchieSoobshcheniya);
    if (soobshcheniya.isEmpty) {
      throw const OslushivanieKlienta(
        HttpStatus.badRequest,
        'Нет текста для отправки.',
      );
    }

    final put = '/v1beta/interactions';
    final zapros = await _klient.postUrl(
      Uri.https('generativelanguage.googleapis.com', put),
    );
    zapros.headers.set('x-goog-api-key', _nastroyki.klyuchGemini);
    zapros.headers.contentType = ContentType.json;
    zapros.write(
      jsonEncode({
        'model': _nastroyki.modelGemini,
        'input': _sobratVhodDlyaVzaimodeistviya(soobshcheniya),
        'store': false,
        'generation_config': {
          'max_output_tokens': 1024,
          'thinking_level': 'low',
        },
      }),
    );

    final otvet = await zapros.close().timeout(const Duration(seconds: 45));
    final telo = await utf8.decoder.bind(otvet).join();
    if (otvet.statusCode != HttpStatus.ok) {
      final oshibkaGemini = _prochitatTekstOshibki(telo);
      throw OslushivanieKlienta(
        otvet.statusCode,
        otvet.statusCode == HttpStatus.tooManyRequests
            ? 'Лимит Gemini временно исчерпан. Попробуйте позже.'
            : 'Ошибка Gemini (${otvet.statusCode}): $oshibkaGemini',
      );
    }

    final dannye = jsonDecode(telo) as Map<String, dynamic>;
    final tekst = _izvlechTekstIzVzaimodeistviya(dannye);
    if (tekst.isEmpty) {
      throw const OslushivanieKlienta(
        HttpStatus.badGateway,
        'Gemini не вернул текстовый ответ.',
      );
    }
    return tekst;
  }

  String _sobratVhodDlyaVzaimodeistviya(
    List<Map<String, dynamic>> soobshcheniya,
  ) {
    final stroki = <String>[
      'Ты Dota AI, полезный ИИ-помощник по Dota 2. Отвечай по-русски.',
      'Ниже история только текущего чата.',
    ];
    for (final soobshchenie in soobshcheniya) {
      final rol = soobshchenie['role'] == 'user' ? 'Пользователь' : 'Dota AI';
      final chasti = soobshchenie['parts'] as List<Map<String, String>>;
      final tekst = chasti.map((chast) => chast['text']).join('\n');
      stroki.add('$rol: $tekst');
    }
    stroki.add('Dota AI:');
    return stroki.join('\n\n');
  }

  String _izvlechTekstIzVzaimodeistviya(Map<String, dynamic> dannye) {
    final shagi = dannye['steps'];
    if (shagi is! List) return '';
    return shagi
        .whereType<Map<String, dynamic>>()
        .where((shag) => shag['type'] == 'model_output')
        .expand((shag) => (shag['content'] as List<dynamic>? ?? const []))
        .whereType<Map<String, dynamic>>()
        .where((chast) => chast['type'] == 'text')
        .map((chast) => chast['text'] as String? ?? '')
        .join()
        .trim();
  }

  String _prochitatTekstOshibki(String telo) {
    try {
      final dannye = jsonDecode(telo) as Map<String, dynamic>;
      final oshibka = dannye['error'];
      if (oshibka is Map<String, dynamic>) {
        final soobshchenie = oshibka['message'];
        if (soobshchenie is String && soobshchenie.isNotEmpty) {
          return soobshchenie;
        }
      }
    } on FormatException {
      // Не показываем пользователю содержимое ответа стороннего сервера.
    }
    return 'сервер не сообщил подробности.';
  }

  List<Map<String, dynamic>> _podgotovitIstoriyu(List<dynamic> soobshcheniya) {
    final rezultat = <Map<String, dynamic>>[];
    const maksimalnoSoobshcheniy = 12;
    final nachalo = soobshcheniya.length > maksimalnoSoobshcheniy
        ? soobshcheniya.length - maksimalnoSoobshcheniy
        : 0;
    for (final syroe in soobshcheniya.skip(nachalo)) {
      if (syroe is! Map<String, dynamic>) continue;
      final rol = syroe['role'];
      final tekst = syroe['text'];
      if ((rol != 'user' && rol != 'model') ||
          tekst is! String ||
          tekst.trim().isEmpty) {
        continue;
      }
      if (rezultat.isEmpty && rol != 'user') continue;
      if (rezultat.isNotEmpty && rezultat.last['role'] == rol) {
        final chasti = rezultat.last['parts'] as List<Map<String, String>>;
        chasti.add({'text': tekst.trim()});
        continue;
      }
      rezultat.add({
        'role': rol,
        'parts': <Map<String, String>>[
          {'text': tekst.trim()},
        ],
      });
    }
    return rezultat;
  }
}

class OslushivanieKlienta implements Exception {
  const OslushivanieKlienta(this.kod, this.tekst);

  final int kod;
  final String tekst;
}
