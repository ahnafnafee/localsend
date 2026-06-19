import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:common/api_route_builder.dart';
import 'package:common/constants.dart';
import 'package:common/model/device.dart';
import 'package:common/model/dto/file_dto.dart';
import 'package:common/model/dto/info_dto.dart';
import 'package:common/model/dto/info_register_dto.dart';
import 'package:common/model/dto/prepare_upload_request_dto.dart';
import 'package:common/model/dto/prepare_upload_response_dto.dart';
import 'package:common/model/stored_security_context.dart';
import 'package:dart_mappable/dart_mappable.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

final _logger = Logger('BackgroundReceiver');

const _uuid = Uuid();

// SharedPreferences keys. These MUST match [PersistenceService] so the
// background isolate reads exactly the same identity/port/alias the main
// isolate persisted.
const _kSecurityContext = 'ls_security_context';
const _kPort = 'ls_port';
const _kAlias = 'ls_alias';
const _kDestination = 'ls_destination';

// Gating keys, read fresh on each prepare-upload so toggles made in the app's
// UI take effect in this isolate. Must match [PersistenceService].
const _kQuickSave = 'ls_quick_save';
const _kQuickSaveFromFavorites = 'ls_quick_save_from_favorites';
const _kFavorites = 'ls_favorites';

// How long the notification prompt waits for the user before defaulting to a
// decline.
const _decisionTimeout = Duration(seconds: 60);

// Progress throttling. `progress` events to the main isolate are emitted at most
// once per [_progressByteInterval] OR [_progressTimeInterval] (whichever comes
// first), so a fast LAN transfer doesn't flood the isolate channel per chunk.
const _progressByteInterval = 64 * 1024; // ~64KB
const _progressTimeInterval = Duration(milliseconds: 100);

// The service-notification text is rewritten far less often (every ~5% or 1s),
// since updateService is comparatively expensive and the notification only needs
// a coarse percentage.
const _notificationInterval = Duration(seconds: 1);

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

  /// File ids the user chose to save (null = save all). Set when the decision is
  /// resolved; `_upload` skips any file id not contained here.
  Set<String>? selectedFileIds;

  _Session({
    required this.sessionId,
    required this.senderIp,
    required this.senderAlias,
    required this.files,
  });
}

/// A LocalSend v2 receive server that runs inside the `flutter_foreground_task`
/// background isolate (see [foreground_service_helper.dart]). It is a direct
/// port of the CLI receiver (`cli/lib/src/receiver.dart`): pure `dart:io`, and
/// handles one session at a time — exactly like the app's main receive server.
///
/// Incoming transfers are gated: auto-accepted only when "quick save" (or "quick
/// save from favorites" for a known sender) is enabled; otherwise the
/// foreground-service notification gets Accept/Decline buttons and the
/// prepare-upload handler blocks on the user's decision (see [resolveDecision]).
///
/// Differences from the CLI version, all app-specific:
/// - The TLS identity is the app's EXISTING stored certificate (read from
///   SharedPreferences), so the background server's fingerprint is identical to
///   the identity peers already trust (trust-on-first-use stays intact).
/// - Files are saved to the app-specific external storage dir (`<external>/LocalSend`).
/// - Logging goes through the `logging` package (no stdout/stderr in this isolate).
class BackgroundReceiver {
  HttpServer? _server;
  _Session? _session;

  /// Non-null while a prepare-upload is waiting for the user's notification
  /// decision. Guards against more than one prompt being pending at a time.
  Completer<bool>? _pendingDecision;

  /// File ids selected by the in-app accept screen for the pending decision
  /// (null = all). Read once when the decision resolves, then folded into the
  /// session so `_upload` only saves the chosen files. Notification-button
  /// accepts leave this null (accept all).
  List<String>? _pendingFileIds;

  /// Session id of the pending prompt, so [resolveDecision] can tell the main
  /// isolate which session was accepted/declined (the notification buttons
  /// otherwise carry no session context).
  String? _pendingSessionId;

  /// Session ids that had at least one failed file, so `session-finished` can
  /// report `hasError`. Cleared when the session finishes.
  final Set<String> _failedFileIds = {};

  String _alias = 'LocalSend';
  int _port = defaultPort;
  String _fingerprint = '';
  late Directory _destination;

  bool get isRunning => _server != null;

  /// Initializes mappers, reads identity/port/alias + the save directory, binds
  /// HTTPS with the app's stored certificate and starts serving. Throws on
  /// failure (the caller in the TaskHandler must catch and log).
  Future<void> start() async {
    _ensureMappers();

    final prefs = await SharedPreferences.getInstance();

    final ctx = _readSecurityContext(prefs);
    _fingerprint = ctx.certificateHash;
    _alias = prefs.getString(_kAlias) ?? 'LocalSend';
    _port = prefs.getInt(_kPort) ?? defaultPort;

    _destination = await _resolveDestinationDir(prefs);
    await _destination.create(recursive: true);

    final securityContext = SecurityContext()
      ..usePrivateKeyBytes(ctx.privateKey.codeUnits)
      ..useCertificateChainBytes(ctx.certificate.codeUnits);

    _server = await HttpServer.bindSecure('0.0.0.0', _port, securityContext);
    _server!.listen(
      (req) => _handle(req).catchError((Object e) => _safeError(req, e)),
      onError: (Object e) => _logger.warning('Server error', e),
    );

    _logger.info('Background receiver started on port $_port (alias "$_alias"). Saving to: ${_destination.path}');

    // Tell the main isolate the server is up so the UI can show "online" while
    // this isolate owns the receive port.
    FlutterForegroundTask.sendDataToMain(jsonEncode({'type': 'server-up', 'alias': _alias, 'port': _port}));
  }

  Future<void> stop() async {
    final session = _session;
    _session = null;
    // If a transfer (or pending prompt) was in flight, tell the main isolate so
    // it can clear its mirror and pop any visible accept/progress screen.
    if (session != null) {
      _failedFileIds.remove(session.sessionId);
      FlutterForegroundTask.sendDataToMain(jsonEncode({'type': 'canceled', 'sessionId': session.sessionId}));
    }
    await _server?.close(force: true);
    _server = null;
    FlutterForegroundTask.sendDataToMain(jsonEncode({'type': 'server-down'}));
    _logger.info('Background receiver stopped.');
  }

  // --- setup helpers -------------------------------------------------------

  /// dart_mappable codegen + the hand-written FileDtoMapper. The main isolate's
  /// initialization does NOT carry over to this isolate, so it must be redone
  /// here (mirrors `_initMappers` in cli/lib/main.dart and `preInit` in the app).
  void _ensureMappers() {
    InfoDtoMapper.ensureInitialized();
    InfoRegisterDtoMapper.ensureInitialized();
    PrepareUploadRequestDtoMapper.ensureInitialized();
    PrepareUploadResponseDtoMapper.ensureInitialized();
    FileMetadataMapper.ensureInitialized();
    MapperContainer.globals.use(const FileDtoMapper());
  }

  StoredSecurityContext _readSecurityContext(SharedPreferences prefs) {
    final raw = prefs.getString(_kSecurityContext);
    if (raw == null) {
      throw StateError('No stored security context ($_kSecurityContext) found for the background receiver.');
    }
    return StoredSecurityContext.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  /// Resolves the save directory. Honors the user's configured destination
  /// (`ls_destination`, shared with the foreground app) as-is; otherwise
  /// defaults to the public `Download/LocalSend`. Android permits direct writes
  /// under `/storage/emulated/0/Download` without all-files-access — saving
  /// anywhere outside it would require the broader permission.
  Future<Directory> _resolveDestinationDir(SharedPreferences prefs) async {
    final configured = prefs.getString(_kDestination);
    if (configured != null && configured.isNotEmpty) {
      return Directory(configured);
    }
    return Directory(p.join('/storage/emulated/0/Download', 'LocalSend'));
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
    if (fp != null && fp == _fingerprint) {
      return _respond(req, 412, message: 'Self-discovered');
    }
    await _respond(req, 200, body: _infoDto().toJson());
  }

  Future<void> _register(HttpRequest req) async {
    try {
      final body = await utf8.decoder.bind(req).join();
      final map = jsonDecode(body) as Map<String, dynamic>;
      if (map['fingerprint'] == _fingerprint) {
        return _respond(req, 412, message: 'Self-discovered');
      }
    } catch (_) {
      return _respond(req, 400, message: 'Request body malformed');
    }
    await _respond(req, 200, body: _infoDto().toJson());
  }

  Future<void> _prepareUpload(HttpRequest req, {required bool legacy}) async {
    if (_session != null) {
      return _respond(req, 409, message: 'Blocked by another session');
    }
    // Only one prompt may be pending at a time. A second prepare-upload arriving
    // while the user hasn't decided yet is treated as busy.
    if (_pendingDecision != null) {
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

    final senderIp = _ipOf(req);

    // The sessionId is generated up front (before the decision) so the in-app
    // accept screen, the `decision` reply, and the `progress` events all share
    // the same id — the main isolate builds its mirror session keyed on it.
    final sessionId = _uuid.v4();

    final accepted = await _decide(dto, sessionId, senderIp);
    if (!accepted) {
      _logger.info('Declined: ${dto.files.length} file(s) from "${dto.info.alias}" ($senderIp)');
      return _respond(req, 403, message: 'File request declined by recipient');
    }

    // The user may have chosen a subset of files in the in-app accept screen.
    // Notification-button accepts leave this null, meaning "save all".
    final selectedFileIds = _pendingFileIds;
    _pendingFileIds = null;

    final files = <String, _IncomingFile>{};
    final responseFiles = <String, String>{};
    for (final entry in dto.files.entries) {
      if (selectedFileIds != null && !selectedFileIds.contains(entry.key)) {
        // File was deselected in the in-app accept screen: don't issue a token,
        // so the sender skips it (mirrors the foreground "skipped" behavior).
        continue;
      }
      final token = _uuid.v4();
      files[entry.key] = _IncomingFile(entry.value, token);
      responseFiles[entry.key] = token;
    }
    _session = _Session(
      sessionId: sessionId,
      senderIp: senderIp,
      senderAlias: dto.info.alias,
      files: files,
    )..selectedFileIds = selectedFileIds?.toSet();

    _logger.info('Accepted: ${files.length} file(s) from "${dto.info.alias}" ($senderIp)');

    if (legacy) {
      await _respond(req, 200, body: responseFiles);
    } else {
      await _respond(req, 200, body: PrepareUploadResponseDto(sessionId: sessionId, files: responseFiles).toJson());
    }
  }

  /// Decides whether to accept [dto]. Auto-accepts when quick-save (or
  /// quick-save-from-favorites for a known sender) is enabled; otherwise prompts
  /// the user via the foreground-service notification and (in parallel) the
  /// in-app accept screen, blocking on whichever resolves first.
  Future<bool> _decide(PrepareUploadRequestDto dto, String sessionId, String senderIp) async {
    final prefs = await SharedPreferences.getInstance();
    // Re-read settings each time so toggles made in the app's UI take effect.
    await prefs.reload();

    final quickSave = prefs.getBool(_kQuickSave) ?? false;
    final quickSaveFromFavorites = prefs.getBool(_kQuickSaveFromFavorites) ?? false;

    if (quickSave || (quickSaveFromFavorites && _isFavorite(prefs, dto.info.fingerprint))) {
      _logger.info('Auto-accepting "${dto.info.alias}" (quickSave=$quickSave, fromFavorites=$quickSaveFromFavorites)');
      return true;
    }

    return _promptUser(dto, sessionId, senderIp);
  }

  /// Returns true if [fingerprint] is among the stored favorites. The favorites
  /// are a StringList of JSON objects; we read each entry's `fingerprint` by
  /// hand rather than depending on the app's FavoriteDevice mapper here. A null
  /// or empty fingerprint (e.g. a v1 sender) can never match a favorite.
  bool _isFavorite(SharedPreferences prefs, String? fingerprint) {
    if (fingerprint == null || fingerprint.isEmpty) {
      return false;
    }
    final raw = prefs.getStringList(_kFavorites);
    if (raw == null) {
      return false;
    }
    for (final entry in raw) {
      try {
        final map = jsonDecode(entry) as Map<String, dynamic>;
        if (map['fingerprint'] == fingerprint) {
          return true;
        }
      } catch (_) {
        // Ignore malformed entries.
      }
    }
    return false;
  }

  /// Shows Accept/Decline buttons on the foreground-service notification and
  /// waits (up to [_decisionTimeout]) for [resolveDecision] to be called from
  /// the TaskHandler. Reverts the notification to its idle state afterwards.
  ///
  /// Before blocking, it pushes an `incoming-request` event to the main isolate
  /// so the app can render its own accept screen; the user can decide there
  /// (via `sendDataToTask` → [resolveDecision]) or on the notification buttons —
  /// whichever happens first resolves the same completer.
  Future<bool> _promptUser(PrepareUploadRequestDto dto, String sessionId, String senderIp) async {
    final completer = Completer<bool>();
    _pendingDecision = completer;
    _pendingSessionId = sessionId;

    // Notify the main isolate so the in-app accept UI can be shown. The file
    // list is serialized with the same FileDto mapper the wire uses, so the main
    // isolate can rebuild lossless FileDto objects.
    FlutterForegroundTask.sendDataToMain(jsonEncode({
      'type': 'incoming-request',
      'sessionId': sessionId,
      'alias': dto.info.alias,
      'fingerprint': dto.info.fingerprint,
      'ip': senderIp,
      'files': [
        for (final f in dto.files.values) const FileDtoMapper().encode(f),
      ],
    }));

    await FlutterForegroundTask.updateService(
      notificationTitle: 'Incoming files from ${dto.info.alias}',
      notificationText: _fileSummary(dto.files.values.toList()),
      notificationButtons: const [
        NotificationButton(id: 'accept', text: 'Accept'),
        NotificationButton(id: 'decline', text: 'Decline'),
      ],
    );

    bool result;
    try {
      result = await completer.future.timeout(_decisionTimeout, onTimeout: () => false);
    } finally {
      _pendingDecision = null;
      _pendingSessionId = null;
      await FlutterForegroundTask.updateService(
        notificationTitle: 'LocalSend',
        notificationText: 'Receiving in the background',
        notificationButtons: const [],
      );
    }
    return result;
  }

  /// Completes a pending decision. Called from the TaskHandler when a
  /// notification button is pressed (no [fileIds] → save all) or when the main
  /// isolate relays the in-app decision via `sendDataToTask` ([fileIds] = the
  /// selected ids). No-op if no prompt is pending. A null [fileIds] (or any
  /// decline) means "all files".
  void resolveDecision(bool accept, [List<String>? fileIds]) {
    final completer = _pendingDecision;
    if (completer != null && !completer.isCompleted) {
      _pendingFileIds = accept ? fileIds : null;
      // Tell the main isolate the outcome so the in-app UI navigates and the
      // resume/tap-to-open path knows whether to show the accept screen or the
      // progress screen. Emitted for BOTH the notification buttons and the
      // in-app accept screen, since both funnel through here.
      final sessionId = _pendingSessionId;
      if (sessionId != null) {
        FlutterForegroundTask.sendDataToMain(jsonEncode(accept
            ? {'type': 'accepted', 'sessionId': sessionId, 'fileIds': fileIds}
            : {'type': 'declined', 'sessionId': sessionId}));
      }
      completer.complete(accept);
    }
  }

  /// Builds the notification text: "<n> file(s): a, b, c(+k more)".
  String _fileSummary(List<FileDto> files) {
    final names = files.map((f) => f.fileName).toList();
    final shown = names.take(3).join(', ');
    final remaining = names.length - 3;
    final suffix = remaining > 0 ? '(+$remaining more)' : '';
    return '${files.length} file(s): $shown$suffix';
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
    if (incoming == null || fileId == null || incoming.token != token) {
      return _respond(req, 403, message: 'Invalid token');
    }

    final total = incoming.dto.size;
    final fileName = incoming.dto.fileName;

    // Tell the main isolate this file started transferring so its mirror flips
    // the file to "sending" and the progress bar appears.
    _sendFileStatus(session.sessionId, fileId, 'sending');

    final destPath = await _resolveDestinationPath(fileName);
    final sink = File(destPath).openWrite();
    var received = 0;
    var lastProgressBytes = 0;
    var lastProgressAt = DateTime.now();
    var lastNotificationPercent = -1;
    var lastNotificationAt = DateTime.fromMillisecondsSinceEpoch(0);
    try {
      // Chunked loop (instead of sink.addStream) so we can observe bytes as they
      // arrive and emit THROTTLED progress — both to the main isolate (every
      // ~64KB or ~100ms) and to the service notification text (every ~5% or 1s).
      await for (final chunk in req) {
        sink.add(chunk);
        received += chunk.length;

        final now = DateTime.now();
        if (received - lastProgressBytes >= _progressByteInterval || now.difference(lastProgressAt) >= _progressTimeInterval) {
          lastProgressBytes = received;
          lastProgressAt = now;
          _sendProgress(session.sessionId, fileId, received, total);
        }

        if (total > 0) {
          final percent = (received * 100 ~/ total);
          if (percent - lastNotificationPercent >= 5 || now.difference(lastNotificationAt) >= _notificationInterval) {
            lastNotificationPercent = percent;
            lastNotificationAt = now;
            // ignore: discarded_futures, unawaited_futures
            FlutterForegroundTask.updateService(notificationText: 'Receiving $fileName — $percent%');
          }
        }
      }
      await sink.flush();
      await sink.close();
    } catch (e) {
      try {
        await sink.close();
      } catch (_) {}
      incoming.done = true;
      _sendFileStatus(session.sessionId, fileId, 'failed');
      _maybeFinishSession(session);
      return _respond(req, 500, message: 'Could not save file: $e');
    }

    // Emit a final 100% so the bar lands exactly full regardless of throttling.
    _sendProgress(session.sessionId, fileId, total, total);

    incoming.done = true;
    _sendFileStatus(session.sessionId, fileId, 'finished');
    _logger.info('Saved: $destPath');
    await _respond(req, 200);

    _maybeFinishSession(session);
  }

  /// Closes the session once every file is done and tells the main isolate the
  /// session finished (so the in-app ProgressPage shows the completed state).
  void _maybeFinishSession(_Session session) {
    if (!session.files.values.every((f) => f.done)) {
      return;
    }
    final hasError = _failedFileIds.contains(session.sessionId);
    _failedFileIds.remove(session.sessionId);
    _logger.info('Session complete (${session.files.length} file(s)) from "${session.senderAlias}".');
    FlutterForegroundTask.sendDataToMain(jsonEncode({
      'type': 'session-finished',
      'sessionId': session.sessionId,
      'hasError': hasError,
    }));
    // ignore: discarded_futures
    FlutterForegroundTask.updateService(
      notificationTitle: 'LocalSend',
      notificationText: 'Receiving in the background',
      notificationButtons: const [],
    );
    if (identical(_session, session)) {
      _session = null;
    }
  }

  void _sendProgress(String sessionId, String fileId, int received, int total) {
    FlutterForegroundTask.sendDataToMain(jsonEncode({
      'type': 'progress',
      'sessionId': sessionId,
      'fileId': fileId,
      'received': received,
      'total': total,
    }));
  }

  void _sendFileStatus(String sessionId, String fileId, String status) {
    if (status == 'failed') {
      _failedFileIds.add(sessionId);
    }
    FlutterForegroundTask.sendDataToMain(jsonEncode({
      'type': 'file-status',
      'sessionId': sessionId,
      'fileId': fileId,
      'status': status,
    }));
  }

  Future<void> _cancel(HttpRequest req) async {
    final session = _session;
    if (session == null) return _respond(req, 200);
    if (_ipOf(req) != session.senderIp) {
      return _respond(req, 403, message: 'No permission');
    }
    _logger.info('Sender "${session.senderAlias}" canceled the session.');
    _session = null;
    _failedFileIds.remove(session.sessionId);
    FlutterForegroundTask.sendDataToMain(jsonEncode({'type': 'canceled', 'sessionId': session.sessionId}));
    await _respond(req, 200);
  }

  // --- helpers -------------------------------------------------------------

  InfoDto _infoDto() => InfoDto(
        alias: _alias,
        version: protocolVersion,
        deviceModel: 'Android',
        deviceType: DeviceType.mobile,
        fingerprint: _fingerprint,
        download: false,
      );

  String _ipOf(HttpRequest req) => req.connectionInfo?.remoteAddress.address ?? '';

  /// Resolves a safe destination path inside [_destination], appending " (n)"
  /// before the extension if a file with that name already exists.
  Future<String> _resolveDestinationPath(String fileName) async {
    final base = p.basename(fileName.replaceAll('\\', '/'));
    final safe = base.isEmpty ? 'file' : base;
    var candidate = p.join(_destination.path, safe);
    if (!await File(candidate).exists()) return candidate;

    final stem = p.basenameWithoutExtension(safe);
    final ext = p.extension(safe);
    var i = 1;
    while (await File(candidate).exists()) {
      candidate = p.join(_destination.path, '$stem ($i)$ext');
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
    _logger.warning('Handler error', e);
    try {
      await _respond(req, 500, message: 'Internal error');
    } catch (_) {}
  }
}
