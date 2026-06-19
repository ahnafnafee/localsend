import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cli/src/tls.dart';
import 'package:common/api_route_builder.dart';
import 'package:common/constants.dart';
import 'package:common/model/device.dart';
import 'package:common/model/dto/file_dto.dart';
import 'package:common/model/dto/info_dto.dart';
import 'package:common/model/dto/prepare_upload_request_dto.dart';
import 'package:common/model/dto/prepare_upload_response_dto.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

const _uuid = Uuid();

class ReceiverConfig {
  final String alias;
  final int port;
  final Directory destination;
  final bool https;
  final String? pin;

  const ReceiverConfig({
    required this.alias,
    required this.port,
    required this.destination,
    required this.https,
    required this.pin,
  });
}

class _IncomingFile {
  final FileDto dto;
  final String token;
  bool done = false;

  _IncomingFile(this.dto, this.token);
}

class _Session {
  final String sessionId;
  final String senderIp;
  final String senderAlias;
  final Map<String, _IncomingFile> files;

  _Session({
    required this.sessionId,
    required this.senderIp,
    required this.senderAlias,
    required this.files,
  });
}

/// A headless LocalSend v2 receiver. Pure `dart:io` — binds the same way the
/// app does (`HttpServer.bindSecure` with a self-signed cert) and auto-accepts
/// every incoming transfer (there is no UI to prompt). One session at a time,
/// exactly like the app's receive server.
class LocalSendReceiver {
  final ReceiverConfig config;
  final TlsCredentials credentials;

  HttpServer? _server;
  _Session? _session;

  LocalSendReceiver({required this.config, required this.credentials});

  String get fingerprint => credentials.fingerprint;

  Future<void> start() async {
    await config.destination.create(recursive: true);

    if (config.https) {
      final context = SecurityContext()
        ..usePrivateKeyBytes(credentials.privateKeyPem.codeUnits)
        ..useCertificateChainBytes(credentials.certificatePem.codeUnits);
      _server = await HttpServer.bindSecure('0.0.0.0', config.port, context);
    } else {
      _server = await HttpServer.bind('0.0.0.0', config.port);
    }

    _server!.listen(
      (req) => _handle(req).catchError((Object e) => _safeError(req, e)),
      onError: (Object e) => stderr.writeln('[server] $e'),
    );
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  // --- routing -------------------------------------------------------------

  Future<void> _handle(HttpRequest req) async {
    final method = req.method;
    final path = req.uri.path;

    bool is_(ApiRoute route) => path == route.v2 || path == route.v1;
    final legacy = path.startsWith('/api/localsend/v1/');

    if (method == 'GET' && is_(ApiRoute.info)) return _info(req);
    if (method == 'POST' && is_(ApiRoute.info)) return _info(req); // some peers POST /info
    if (method == 'POST' && is_(ApiRoute.register)) return _register(req);
    if (method == 'POST' && is_(ApiRoute.prepareUpload)) return _prepareUpload(req, legacy: legacy);
    if (method == 'POST' && is_(ApiRoute.upload)) return _upload(req, legacy: legacy);
    if (method == 'POST' && is_(ApiRoute.cancel)) return _cancel(req);

    await _respond(req, 404, message: 'Not found');
  }

  // --- handlers ------------------------------------------------------------

  Future<void> _info(HttpRequest req) async {
    final fp = req.uri.queryParameters['fingerprint'];
    if (fp != null && fp == fingerprint) {
      return _respond(req, 412, message: 'Self-discovered');
    }
    await _respond(req, 200, body: _infoDto().toJson());
  }

  Future<void> _register(HttpRequest req) async {
    try {
      final body = await utf8.decoder.bind(req).join();
      final map = jsonDecode(body) as Map<String, dynamic>;
      if (map['fingerprint'] == fingerprint) {
        return _respond(req, 412, message: 'Self-discovered');
      }
    } catch (_) {
      return _respond(req, 400, message: 'Request body malformed');
    }
    await _respond(req, 200, body: _infoDto().toJson());
  }

  Future<void> _prepareUpload(HttpRequest req, {required bool legacy}) async {
    if (config.pin != null && req.uri.queryParameters['pin'] != config.pin) {
      return _respond(req, 401, message: 'Invalid pin.');
    }
    if (_session != null) {
      return _respond(req, 409, message: 'Blocked by another session');
    }

    final PrepareUploadRequestDto dto;
    try {
      final body = await utf8.decoder.bind(req).join();
      dto = PrepareUploadRequestDto.fromJson(jsonDecode(body) as Map<String, dynamic>);
    } catch (_) {
      return _respond(req, 400, message: 'Request body malformed');
    }
    if (dto.files.isEmpty) {
      return _respond(req, 400, message: 'Request must contain at least one file');
    }

    final sessionId = _uuid.v4();
    final senderIp = _ipOf(req);
    final files = <String, _IncomingFile>{};
    final responseFiles = <String, String>{};
    for (final entry in dto.files.entries) {
      final token = _uuid.v4();
      files[entry.key] = _IncomingFile(entry.value, token);
      responseFiles[entry.key] = token;
    }
    _session = _Session(
      sessionId: sessionId,
      senderIp: senderIp,
      senderAlias: dto.info.alias,
      files: files,
    );

    _log('Incoming: ${dto.files.length} file(s) from "${dto.info.alias}" ($senderIp) — auto-accepting');

    if (legacy) {
      await _respond(req, 200, body: responseFiles);
    } else {
      await _respond(req, 200, body: PrepareUploadResponseDto(sessionId: sessionId, files: responseFiles).toJson());
    }
  }

  Future<void> _upload(HttpRequest req, {required bool legacy}) async {
    final session = _session;
    if (session == null) return _respond(req, 409, message: 'No session');

    final q = req.uri.queryParameters;
    final sessionId = q['sessionId'];
    final fileId = q['fileId'];
    final token = q['token'];
    if (!legacy && (sessionId == null || fileId == null || token == null)) {
      return _respond(req, 400, message: 'Missing parameters');
    }
    if (_ipOf(req) != session.senderIp) {
      return _respond(req, 403, message: 'Invalid IP address');
    }
    if (!legacy && sessionId != session.sessionId) {
      return _respond(req, 403, message: 'Invalid session id');
    }
    final incoming = fileId == null ? null : session.files[fileId];
    if (incoming == null || incoming.token != token) {
      return _respond(req, 403, message: 'Invalid token');
    }

    final destPath = await _resolveDestinationPath(incoming.dto.fileName);
    final sink = File(destPath).openWrite();
    try {
      await sink.addStream(req);
      await sink.flush();
      await sink.close();
    } catch (e) {
      try {
        await sink.close();
      } catch (_) {}
      return _respond(req, 500, message: 'Could not save file: $e');
    }

    incoming.done = true;
    _log('Saved: $destPath');
    await _respond(req, 200);

    if (session.files.values.every((f) => f.done)) {
      _log('Session complete (${session.files.length} file(s)) from "${session.senderAlias}".');
      _session = null;
    }
  }

  Future<void> _cancel(HttpRequest req) async {
    final session = _session;
    if (session == null) return _respond(req, 200);
    if (_ipOf(req) != session.senderIp) {
      return _respond(req, 403, message: 'No permission');
    }
    _log('Sender "${session.senderAlias}" canceled the session.');
    _session = null;
    await _respond(req, 200);
  }

  // --- helpers -------------------------------------------------------------

  InfoDto _infoDto() => InfoDto(
        alias: config.alias,
        version: protocolVersion,
        deviceModel: 'cli',
        deviceType: DeviceType.headless,
        fingerprint: fingerprint,
        download: false,
      );

  String _ipOf(HttpRequest req) => req.connectionInfo?.remoteAddress.address ?? '';

  /// Resolves a safe destination path inside [config.destination], appending
  /// " (n)" before the extension if a file with that name already exists.
  Future<String> _resolveDestinationPath(String fileName) async {
    final base = p.basename(fileName.replaceAll('\\', '/'));
    final safe = base.isEmpty ? 'file' : base;
    var candidate = p.join(config.destination.path, safe);
    if (!await File(candidate).exists()) return candidate;

    final stem = p.basenameWithoutExtension(safe);
    final ext = p.extension(safe);
    var i = 1;
    while (await File(candidate).exists()) {
      candidate = p.join(config.destination.path, '$stem ($i)$ext');
      i++;
    }
    return candidate;
  }

  Future<void> _respond(HttpRequest req, int code, {String? message, Object? body}) async {
    req.response.statusCode = code;
    req.response.headers.contentType = ContentType.json;
    final payload = message != null ? {'message': message} : (body ?? <String, dynamic>{});
    req.response.write(jsonEncode(payload));
    await req.response.close();
  }

  Future<void> _safeError(HttpRequest req, Object e) async {
    stderr.writeln('[handler] $e');
    try {
      await _respond(req, 500, message: 'Internal error');
    } catch (_) {}
  }

  void _log(String msg) {
    final now = DateTime.now().toIso8601String().substring(11, 19);
    stdout.writeln('[$now] $msg');
  }
}
