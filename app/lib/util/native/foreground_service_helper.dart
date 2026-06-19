import 'dart:ui';

import 'package:flutter/widgets.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/util/native/background_receiver.dart';
import 'package:localsend_app/util/native/platform_check.dart';
import 'package:logging/logging.dart';

final _logger = Logger('ForegroundService');

const _serviceId = 424242;
const _channelId = 'localsend_receive_background';

/// Entry point of the `flutter_foreground_task` background isolate. This runs in
/// the foreground-service process, which survives the app being backgrounded /
/// the task being removed (`stopWithTask=false`), so the receive server hosted
/// here ([_KeepAliveTaskHandler]) keeps serving after the UI is gone.
///
/// Because this is a fresh isolate, the plugin registrant must be initialized
/// here so plugins like `shared_preferences` and `path_provider` work — the main
/// isolate's initialization does not carry over.
///
/// See [https://developer.android.com/about/versions/14/changes/fgs-types-required#data-sync]
@pragma('vm:entry-point')
void startBackgroundCallback() {
  WidgetsFlutterBinding.ensureInitialized();

  // The `logging` package's root logger has no listeners in this fresh isolate,
  // so route its records to debugPrint to make them visible in logcat.
  Logger.root.level = Level.INFO;
  Logger.root.onRecord.listen((r) {
    debugPrint('[LS-bg] ${r.level.name} ${r.loggerName}: ${r.message}');
  });

  DartPluginRegistrant.ensureInitialized();
  FlutterForegroundTask.setTaskHandler(_KeepAliveTaskHandler());
}

/// Hosts the [BackgroundReceiver] in the background isolate. When
/// `runInBackground` is ON, this isolate OWNS receiving (the main isolate's
/// server is stopped), so it binds the LocalSend port here.
class _KeepAliveTaskHandler extends TaskHandler {
  final BackgroundReceiver _receiver = BackgroundReceiver();

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    try {
      await _receiver.start();
    } catch (e, st) {
      // Never let a startup failure crash the isolate — the foreground service
      // must keep running so the user can recover by toggling the setting.
      _logger.severe('Failed to start background receiver', e, st);
    }
  }

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  void onNotificationButtonPressed(String id) {
    _receiver.resolveDecision(id == 'accept');
  }

  @override
  void onNotificationPressed() {
    // The in-app decision path is a later milestone; for now just open the app.
    FlutterForegroundTask.launchApp();
  }

  @override
  Future<void> onDestroy(DateTime timestamp) async {
    try {
      await _receiver.stop();
    } catch (e, st) {
      _logger.warning('Failed to stop background receiver', e, st);
    }
  }
}

/// Configures the foreground service. Must be called once early (e.g. in [main])
/// before [startBackgroundService] can be used. No-op on non-Android platforms.
Future<void> initForegroundService() async {
  if (!checkPlatform([TargetPlatform.android])) {
    return;
  }

  FlutterForegroundTask.init(
    androidNotificationOptions: AndroidNotificationOptions(
      channelId: _channelId,
      channelName: t.settingsTab.receive.runInBackground,
      channelDescription: t.settingsTab.receive.runInBackgroundDescription,
      onlyAlertOnce: true,
    ),
    iosNotificationOptions: const IOSNotificationOptions(
      showNotification: false,
      playSound: false,
    ),
    foregroundTaskOptions: ForegroundTaskOptions(
      // We don't need repeating events; the service just keeps the process alive.
      eventAction: ForegroundTaskEventAction.nothing(),
      autoRunOnBoot: false,
      autoRunOnMyPackageReplaced: false,
      allowWakeLock: true,
      allowWifiLock: true,
    ),
  );
}

/// Requests the runtime permissions needed for reliable background receiving:
/// the Android 13+ notification permission (the foreground-service notification
/// is mandatory) and a battery-optimization exemption (so aggressive OEM power
/// management is less likely to kill the process despite the foreground service).
///
/// Call this from a FOREGROUND context (e.g. when the user enables the setting) —
/// never while the app is backgrounding, since these system prompts need UI.
/// No-op on non-Android platforms.
Future<void> requestBackgroundPermissions() async {
  if (!checkPlatform([TargetPlatform.android])) {
    return;
  }
  if (await FlutterForegroundTask.checkNotificationPermission() != NotificationPermission.granted) {
    await FlutterForegroundTask.requestNotificationPermission();
  }
  await FlutterForegroundTask.requestIgnoreBatteryOptimization();
}

/// Starts the foreground service so receiving keeps working while backgrounded.
/// Idempotent. MUST be called from a foreground context — Android 12+ forbids
/// starting a foreground service from the background. No-op on non-Android
/// platforms, if already running, or if the notification permission is missing
/// (call [requestBackgroundPermissions] first, when the user enables the setting).
Future<void> startBackgroundService() async {
  if (!checkPlatform([TargetPlatform.android])) {
    return;
  }

  if (await FlutterForegroundTask.isRunningService) {
    return;
  }

  if (await FlutterForegroundTask.checkNotificationPermission() != NotificationPermission.granted) {
    _logger.warning('Notification permission not granted; not starting foreground service.');
    return;
  }

  final result = await FlutterForegroundTask.startService(
    serviceId: _serviceId,
    notificationTitle: t.appName,
    notificationText: t.settingsTab.receive.runInBackgroundDescription,
    callback: startBackgroundCallback,
  );

  if (result is ServiceRequestFailure) {
    _logger.warning('Failed to start foreground service', result.error);
  }
}

/// Stops the foreground service if it is running. No-op on non-Android platforms.
Future<void> stopBackgroundService() async {
  if (!checkPlatform([TargetPlatform.android])) {
    return;
  }

  if (!await FlutterForegroundTask.isRunningService) {
    return;
  }

  await FlutterForegroundTask.stopService();
}
