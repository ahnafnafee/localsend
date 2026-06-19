import 'package:refena_flutter/refena_flutter.dart';

/// Mirror of the background receive server's liveness, pushed from the
/// `flutter_foreground_task` background isolate to the main isolate.
///
/// On Android, when "keep receiving in the background" is ON, the background
/// isolate OWNS the receive port and the main-isolate [serverProvider] is null
/// (see `ServerService.startServer`). The UI keys "online" off the main server,
/// so without this it would wrongly show "offline" while the bg isolate serves.
/// The main isolate listens for the isolate's data events and updates this
/// provider (see `addTaskDataCallback` registration in `main.dart`).
class BackgroundReceiverState {
  /// Whether the background receive server is currently bound and serving.
  final bool online;

  /// The alias the background server advertises (null while offline).
  final String? alias;

  /// The port the background server is bound to (null while offline).
  final int? port;

  const BackgroundReceiverState({
    required this.online,
    required this.alias,
    required this.port,
  });

  const BackgroundReceiverState.offline()
      : online = false,
        alias = null,
        port = null;
}

final backgroundReceiverProvider = NotifierProvider<BackgroundReceiverService, BackgroundReceiverState>((ref) {
  return BackgroundReceiverService();
});

class BackgroundReceiverService extends PureNotifier<BackgroundReceiverState> {
  @override
  BackgroundReceiverState init() => const BackgroundReceiverState.offline();

  void setOnline(String alias, int port) {
    state = BackgroundReceiverState(online: true, alias: alias, port: port);
  }

  void setOffline() {
    state = const BackgroundReceiverState.offline();
  }
}
