import 'dart:async';
import 'dart:convert';

import 'package:common/constants.dart';
import 'package:common/isolate.dart';
import 'package:common/model/device.dart';
import 'package:common/model/dto/file_dto.dart';
import 'package:common/model/file_status.dart';
import 'package:common/model/session_status.dart';
import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:localsend_app/config/init.dart';
import 'package:localsend_app/config/init_error.dart';
import 'package:localsend_app/config/theme.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/model/persistence/color_mode.dart';
import 'package:localsend_app/model/state/server/receive_session_state.dart';
import 'package:localsend_app/model/state/server/receiving_file.dart';
import 'package:localsend_app/pages/home_page.dart';
import 'package:localsend_app/pages/progress_page.dart';
import 'package:localsend_app/pages/receive_page.dart';
import 'package:localsend_app/provider/background_receiver_provider.dart';
import 'package:localsend_app/provider/background_session_provider.dart';
import 'package:localsend_app/provider/local_ip_provider.dart';
import 'package:localsend_app/provider/progress_provider.dart';
import 'package:localsend_app/provider/selection/selected_receiving_files_provider.dart';
import 'package:localsend_app/provider/settings_provider.dart';
import 'package:localsend_app/util/native/foreground_service_helper.dart';
import 'package:localsend_app/util/native/platform_check.dart';
import 'package:localsend_app/util/ui/dynamic_colors.dart';
import 'package:localsend_app/widget/watcher/life_cycle_watcher.dart';
import 'package:localsend_app/widget/watcher/shortcut_watcher.dart';
import 'package:localsend_app/widget/watcher/tray_watcher.dart';
import 'package:localsend_app/widget/watcher/window_watcher.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:routerino/routerino.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> main(List<String> args) async {
  final RefenaContainer container;
  try {
    container = await preInit(args);
  } catch (e, stackTrace) {
    showInitErrorApp(
      error: e,
      stackTrace: stackTrace,
    );
    return;
  }

  if (checkPlatform([TargetPlatform.android])) {
    // Initialize the foreground service used by the "keep receiving in the background" setting.
    FlutterForegroundTask.initCommunicationPort();

    // The background isolate (the foreground-service receiver) pushes liveness
    // events here so the UI can reflect "online" even though the main-isolate
    // server is null while the bg isolate owns the port. Registered once, right
    // after initCommunicationPort(), with the global container in scope as `ref`.
    FlutterForegroundTask.addTaskDataCallback((data) => _onBgData(container, data));

    await initForegroundService();
  }

  runApp(
    RefenaScope.withContainer(
      container: container,
      child: TranslationProvider(
        child: const LocalSendApp(),
      ),
    ),
  );
}

/// Decodes an event from the background-receive isolate and updates the relevant
/// main-isolate provider. [ref] is the global [RefenaContainer] from [main].
///
/// Liveness events (`server-up` / `server-down`) drive [backgroundReceiverProvider].
/// Transfer events mirror the background session into [backgroundSessionProvider]
/// (and [progressProvider]) so the existing receive/progress UI can render a
/// transfer that the background isolate actually owns. Unknown types are ignored.
void _onBgData(Ref ref, Object data) {
  if (data is! String) {
    return;
  }
  final m = jsonDecode(data) as Map<String, dynamic>;
  debugPrint('[LS-main] bg event: ${m['type']}');
  switch (m['type']) {
    case 'server-up':
      ref.notifier(backgroundReceiverProvider).setOnline(m['alias'] as String, m['port'] as int);
      break;
    case 'server-down':
      ref.notifier(backgroundReceiverProvider).setOffline();
      break;
    case 'incoming-request':
      _onIncomingRequest(ref, m);
      break;
    case 'progress':
      {
        final total = (m['total'] as num).toInt();
        if (total > 0) {
          ref.notifier(progressProvider).setProgress(
                sessionId: m['sessionId'] as String,
                fileId: m['fileId'] as String,
                progress: (m['received'] as num) / total,
              );
        }
      }
      break;
    case 'file-status':
      _onFileStatus(ref, m);
      break;
    case 'session-finished':
      _onSessionFinished(ref, m);
      break;
    case 'accepted':
      _onAccepted(ref, m);
      break;
    case 'declined':
      _onDeclined(ref, m);
      break;
    case 'canceled':
      _onCanceled(ref, m);
      break;
  }
}

/// Rebuilds a [ReceiveSessionState] (status = waiting) from an `incoming-request`
/// payload, stores it in [backgroundSessionProvider], and pushes the in-app
/// accept screen ([ReceivePage]).
void _onIncomingRequest(Ref ref, Map<String, dynamic> m) {
  final sessionId = m['sessionId'] as String;
  final alias = m['alias'] as String;
  final fingerprint = m['fingerprint'] as String? ?? '';
  final files = <String, ReceivingFile>{};
  for (final raw in (m['files'] as List)) {
    final dto = const FileDtoMapper().decode(raw);
    files[dto.id] = ReceivingFile(
      file: dto,
      status: FileStatus.queue,
      token: null,
      desiredName: null,
      path: null,
      savedToGallery: false,
      errorMessage: null,
    );
  }

  final sender = Device.empty.copyWith(
    alias: alias,
    fingerprint: fingerprint,
    deviceType: DeviceType.mobile,
    // Set the sender IP so ReceivePage shows the normal "#<ip>" LAN badge
    // instead of the "WebRTC" fallback it renders when ip is null.
    ip: m['ip'] as String?,
  );

  final session = ReceiveSessionState(
    sessionId: sessionId,
    status: SessionStatus.waiting,
    sender: sender,
    senderAlias: alias,
    files: files,
    startTime: null,
    endTime: null,
    // Display-only; real save dir lives in the background isolate.
    destinationDirectory: '',
    cacheDirectory: '',
    saveToGallery: false,
    createdDirectories: {},
    // The decision crosses isolates via sendDataToTask, never through this
    // controller — it exists only because the field is non-nullable in the
    // waiting state's usual construction. It is never listened to or added to.
    responseHandler: StreamController<Map<String, String>?>(),
  );

  ref.notifier(backgroundSessionProvider).setSession(session);
  _showBackgroundReceivePage(ref);
}

/// Builds the [ReceivePageVm] for the background session (mirroring
/// receive_controller.dart's foreground VM) and pushes [ReceivePage]. Idempotent
/// for a given session via [BackgroundSessionState.shown]; safe to call again on
/// app resume (tap-to-open).
void _showBackgroundReceivePage(Ref ref) {
  final current = ref.read(backgroundSessionProvider);
  if (current.session == null || current.shown) {
    return;
  }

  // The navigator may not be mounted yet if a notification tap woke a killed
  // app and this event arrived before the first frame. Leave `shown` false so
  // the resume post-frame callback renders it once the navigator exists.
  if (Routerino.navigatorKey.currentState == null) {
    return;
  }
  final sessionId = current.session!.sessionId;

  final receiveProvider = ViewProvider((ref) {
    final session = ref.watch(backgroundSessionProvider.select((s) => s.session));
    return ReceivePageVm(
      status: session?.status,
      sender: session?.sender ?? Device.empty,
      showSenderInfo: true,
      files: session?.files.values.map((f) => f.file).toList() ?? [],
      message: null,
      onAccept: () async {
        final selectedFiles = ref.read(selectedReceivingFilesProvider);
        FlutterForegroundTask.sendDataToTask(jsonEncode({
          'type': 'decision',
          'accept': true,
          'fileIds': selectedFiles.keys.toList(),
        }));

        // Mirror the selection: files the user deselected become `skipped` so
        // ProgressPage's totals/count exclude them (the background isolate also
        // skips them — they were sent no token). Status flips to sending; the
        // per-file progress arrives via `progress`/`file-status` events.
        final current = ref.read(backgroundSessionProvider).session;
        if (current != null) {
          ref.notifier(backgroundSessionProvider).updateSession(current.copyWith(
                status: SessionStatus.sending,
                files: {
                  for (final entry in current.files.entries)
                    entry.key: entry.value.copyWith(
                      status: selectedFiles.containsKey(entry.key) ? FileStatus.queue : FileStatus.skipped,
                      desiredName: selectedFiles[entry.key],
                    ),
                },
              ));
        }

        // Route navigation through the shared idempotent helper so it marks
        // `progressShown` — a later resume then no-ops instead of re-pushing.
        debugPrint('[LS-main] in-app accept: session $sessionId -> sending; ensuring ProgressPage');
        _ensureProgressPageShown(ref, sessionId);
      },
      onDecline: () {
        FlutterForegroundTask.sendDataToTask(jsonEncode({
          'type': 'decision',
          'accept': false,
        }));
        ref.notifier(backgroundSessionProvider).clear();
      },
      onClose: () {
        ref.notifier(backgroundSessionProvider).clear();
      },
    );
  });

  ref.notifier(backgroundSessionProvider).markShown();
  // ignore: discarded_futures
  Routerino.context.push(() => ReceivePage(receiveProvider));
}

/// Applies a `file-status` event to the mirror session (sending / finished /
/// failed). Updating the session is what drives ProgressPage's per-file rows and
/// the overall finished/error state.
void _onFileStatus(Ref ref, Map<String, dynamic> m) {
  final notifier = ref.notifier(backgroundSessionProvider);
  final session = notifier.session;
  if (session == null || session.sessionId != m['sessionId']) {
    return;
  }
  final fileId = m['fileId'] as String;
  final existing = session.files[fileId];
  if (existing == null) {
    return;
  }
  final status = switch (m['status'] as String) {
    'sending' => FileStatus.sending,
    'finished' => FileStatus.finished,
    'failed' => FileStatus.failed,
    _ => existing.status,
  };

  notifier.updateSession(session.copyWith(
    status: SessionStatus.sending,
    startTime: session.startTime ?? DateTime.now().millisecondsSinceEpoch,
    files: {...session.files}..update(fileId, (f) => f.copyWith(status: status)),
  ));
}

/// Marks the mirror session finished (so ProgressPage shows the completed
/// state). The session row data is kept; only the status/endTime change.
void _onSessionFinished(Ref ref, Map<String, dynamic> m) {
  final notifier = ref.notifier(backgroundSessionProvider);
  final session = notifier.session;
  if (session == null || session.sessionId != m['sessionId']) {
    return;
  }
  final hasError = m['hasError'] as bool? ?? false;
  notifier.updateSession(session.copyWith(
    status: hasError ? SessionStatus.finishedWithErrors : SessionStatus.finished,
    endTime: DateTime.now().millisecondsSinceEpoch,
  ));
}

/// Ensures [ProgressPage] is the active screen for [sessionId], replacing a stale
/// [ReceivePage] if one is on top. Idempotent and safe to call from BOTH the
/// notification/resume path and the in-app accept path: navigation happens at
/// most once per session, tracked via [BackgroundSessionState.progressShown]
/// (the app has no [RouterinoObserver], so the live route stack can't be read).
///
/// No-op if the navigator isn't mounted yet — the resume post-frame callback will
/// retry once it exists. Marking `progressShown` only on a real push keeps that
/// retry path intact.
void _ensureProgressPageShown(Ref ref, String sessionId) {
  final state = ref.read(backgroundSessionProvider);
  if (state.progressShown) {
    // ProgressPage was already pushed for this session; do nothing.
    return;
  }
  if (Routerino.navigatorKey.currentState == null) {
    // Navigator not mounted yet (e.g. app still resuming). Leave progressShown
    // false so the resume post-frame callback navigates once it exists.
    return;
  }
  // An immediate navigation issued while the app is paused (e.g. the notification
  // Accept button was tapped from the shade) does not stick. Only navigate — and
  // only mark `progressShown` — when the app is actually resumed; otherwise leave
  // the flag false so the resume post-frame callback is the one that navigates.
  if (WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
    debugPrint('[LS-main] _ensureProgressPageShown: app not resumed (${WidgetsBinding.instance.lifecycleState}); deferring to resume path');
    return;
  }
  ref.notifier(backgroundSessionProvider).markProgressShown();
  // ignore: discarded_futures
  Routerino.context.pushAndRemoveUntilImmediately(
    removeUntil: ReceivePage,
    builder: () => ProgressPage(
      showAppBar: false,
      closeSessionOnClose: true,
      sessionId: sessionId,
    ),
  );
}

/// Handles an `accepted` event. The background isolate emits this for BOTH the
/// notification Accept button and the in-app Accept button, but the in-app path
/// already moved the mirror out of `waiting` and navigated itself — so this is
/// guarded on the session still being `waiting`, making it the navigator for the
/// NOTIFICATION path only (no double-push). It flips the mirror to `sending`
/// (marking the chosen files) and routes navigation through the shared idempotent
/// [_ensureProgressPageShown] helper. If the app isn't foreground, the status
/// change alone is enough for the resume/tap-to-open path to land on ProgressPage.
void _onAccepted(Ref ref, Map<String, dynamic> m) {
  final notifier = ref.notifier(backgroundSessionProvider);
  final state = ref.read(backgroundSessionProvider);
  final session = state.session;
  if (session == null || session.sessionId != m['sessionId']) {
    return;
  }
  if (session.status != SessionStatus.waiting) {
    // The in-app accept path already handled navigation + status.
    debugPrint('[LS-main] _onAccepted: session ${session.sessionId} already ${session.status.name}; skipping (in-app path handled it)');
    return;
  }
  final fileIds = (m['fileIds'] as List?)?.cast<String>();
  notifier.updateSession(session.copyWith(
    status: SessionStatus.sending,
    files: {
      for (final entry in session.files.entries)
        entry.key: entry.value.copyWith(
          status: (fileIds == null || fileIds.contains(entry.key)) ? FileStatus.queue : FileStatus.skipped,
        ),
    },
  ));

  final navMounted = Routerino.navigatorKey.currentState != null;
  debugPrint('[LS-main] _onAccepted: session ${session.sessionId} -> sending; shown=${state.shown}, progressShown=${state.progressShown}, navMounted=$navMounted');
  if (state.shown) {
    // Accept screen is showing in the foreground: swap it for ProgressPage now.
    _ensureProgressPageShown(ref, session.sessionId);
  }
  // If not shown (app paused/killed), the resume path navigates on the status.
}

/// Handles a `declined` event. The in-app decline path already clears the mirror
/// and pops its own page, so this acts only for the NOTIFICATION decline (mirror
/// still present): pop the accept screen if it's showing, then clear the mirror.
void _onDeclined(Ref ref, Map<String, dynamic> m) {
  final notifier = ref.notifier(backgroundSessionProvider);
  final state = ref.read(backgroundSessionProvider);
  final session = state.session;
  if (session == null || session.sessionId != m['sessionId']) {
    return;
  }
  if (state.shown) {
    final nav = Routerino.navigatorKey.currentState;
    if (nav != null && nav.canPop()) {
      nav.pop();
    }
  }
  notifier.clear();
}

/// Handles a `canceled` event (sender canceled, or the service was stopped
/// mid-session). Flips the mirror to `canceledBySender` so a visible
/// `ReceivePage`/`ProgressPage` renders its normal canceled state (with a Close
/// button the user dismisses, which clears the mirror). If nothing is showing
/// yet, the mirror is cleared outright.
void _onCanceled(Ref ref, Map<String, dynamic> m) {
  final notifier = ref.notifier(backgroundSessionProvider);
  final state = ref.read(backgroundSessionProvider);
  final session = state.session;
  if (session == null || session.sessionId != m['sessionId']) {
    return;
  }
  if (state.shown) {
    notifier.updateSession(session.copyWith(
      status: SessionStatus.canceledBySender,
      endTime: DateTime.now().millisecondsSinceEpoch,
    ));
  } else {
    notifier.clear();
  }
}

/// On app resume, reconcile the visible screen with the background session's
/// STATUS — this is the reliable navigator for the paused/notification path,
/// because an immediate `pushAndRemoveUntilImmediately` issued while the app was
/// paused (e.g. from the notification's Accept button) does not stick.
///
/// Keyed on status, NOT gated on `shown`:
/// - no session → nothing to do.
/// - `waiting` → show the accept screen, but only if it hasn't been shown yet
///   (otherwise the already-visible accept screen is correct).
/// - otherwise (`sending` / `finished` / `finishedWithErrors` / canceled) → ensure
///   ProgressPage is on top via the idempotent helper, replacing a stale accept
///   screen. Safe to run on every resume: the helper no-ops once ProgressPage is up.
void _showBackgroundSessionOnResume(Ref ref) {
  WidgetsBinding.instance.addPostFrameCallback((_) {
    final current = ref.read(backgroundSessionProvider);
    final session = current.session;
    if (session == null) {
      return;
    }
    debugPrint('[LS-main] onResume: session ${session.sessionId} status=${session.status.name}, shown=${current.shown}, progressShown=${current.progressShown}');
    if (session.status == SessionStatus.waiting) {
      if (!current.shown) {
        debugPrint('[LS-main] onResume: showing ReceivePage (waiting)');
        _showBackgroundReceivePage(ref);
      }
    } else {
      debugPrint('[LS-main] onResume: ensuring ProgressPage (status=${session.status.name})');
      _ensureProgressPageShown(ref, session.sessionId);
    }
  });
}

// SharedPreferences keys shared with the background isolate (see
// `background_receiver.dart` / `persistence_provider.dart`). The background
// server binds to exactly these, so reading them here makes the "online"
// indicator reflect what the bg server is actually advertising.
const _kPrefAlias = 'ls_alias';
const _kPrefPort = 'ls_port';

/// Reconciles [backgroundReceiverProvider]'s online state with reality on every
/// resume (and right after starting the service), instead of trusting only the
/// `server-up` / `server-down` events — those race the listener and a missed one
/// can wrongly leave the Receive tab showing "Offline" while the bg server still
/// serves. Source of truth: [FlutterForegroundTask.isRunningService]. Alias/port
/// are read from the same prefs keys the bg isolate binds to. No-op off Android.
Future<void> _reconcileBackgroundOnline(Ref ref) async {
  if (!checkPlatform([TargetPlatform.android])) {
    return;
  }
  final running = await FlutterForegroundTask.isRunningService;
  if (running) {
    final prefs = await SharedPreferences.getInstance();
    final alias = prefs.getString(_kPrefAlias) ?? 'LocalSend';
    final port = prefs.getInt(_kPrefPort) ?? defaultPort;
    debugPrint('[LS-main] reconcileOnline: service running -> setOnline(alias=$alias, port=$port)');
    ref.notifier(backgroundReceiverProvider).setOnline(alias, port);
  } else {
    debugPrint('[LS-main] reconcileOnline: service not running -> setOffline');
    ref.notifier(backgroundReceiverProvider).setOffline();
  }
}

class LocalSendApp extends StatelessWidget {
  const LocalSendApp();

  @override
  Widget build(BuildContext context) {
    final ref = context.ref;
    final (themeMode, colorMode) = ref.watch(settingsProvider.select((settings) => (settings.theme, settings.colorMode)));
    final dynamicColors = ref.watch(dynamicColorsProvider);
    return TrayWatcher(
      child: WindowWatcher(
        child: LifeCycleWatcher(
          onChangedState: (AppLifecycleState state) {
            switch (state) {
              case AppLifecycleState.resumed:
                ref.redux(localIpProvider).dispatch(InitLocalIpAction());
                // Ensure the foreground service is running whenever the user enabled
                // background receiving. Starting it here (a foreground context) avoids
                // Android 12+'s restriction on starting a foreground service from the
                // background; it then survives the app being backgrounded.
                if (checkPlatform([TargetPlatform.android]) && ref.read(settingsProvider).runInBackground) {
                  // Start the service (idempotent), THEN reconcile the online
                  // indicator against the actual service state — covers a service
                  // that was restarted while backgrounded and whose `server-up`
                  // event the main isolate missed.
                  unawaited(() async {
                    await startBackgroundService();
                    await _reconcileBackgroundOnline(ref);
                  }());
                  // Also reconcile immediately so the indicator self-corrects on
                  // resume even when the service was already running (start is a
                  // no-op) and no fresh `server-up` will arrive.
                  unawaited(_reconcileBackgroundOnline(ref));
                  // Tap-to-open: a notification tap that wakes the app should show
                  // the buffered background transfer's accept (or progress) screen.
                  _showBackgroundSessionOnResume(ref);
                }
                break;
              case AppLifecycleState.detached:
                // The main isolate is only exited when all child isolates are exited.
                // https://github.com/localsend/localsend/issues/1568
                ref.redux(parentIsolateProvider).dispatch(IsolateDisposeAction());
                break;
              default:
                break;
            }
          },
          child: ShortcutWatcher(
            child: MaterialApp(
              title: t.appName,
              locale: TranslationProvider.of(context).flutterLocale,
              supportedLocales: AppLocaleUtils.supportedLocales,
              localizationsDelegates: GlobalMaterialLocalizations.delegates,
              debugShowCheckedModeBanner: false,
              theme: getTheme(colorMode, Brightness.light, dynamicColors),
              darkTheme: getTheme(colorMode, Brightness.dark, dynamicColors),
              themeMode: colorMode == ColorMode.oled ? ThemeMode.dark : themeMode,
              navigatorKey: Routerino.navigatorKey,
              home: RouterinoHome(
                builder: () => const HomePage(
                  initialTab: HomeTab.receive,
                  appStart: true,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
