import 'package:localsend_app/model/state/server/receive_session_state.dart';
import 'package:refena_flutter/refena_flutter.dart';

/// Mirror of the receive session owned by the `flutter_foreground_task`
/// background isolate, reconstructed on the main isolate from the isolate's data
/// events (see `_onBgData` in `main.dart`).
///
/// When "keep receiving in the background" is ON (Android), the background
/// isolate owns the receive port and the main-isolate [serverProvider] session
/// is always null — the foreground UI has nothing to render. This provider holds
/// a faithful [ReceiveSessionState] so the existing `ReceivePage` / `ProgressPage`
/// (which key off `serverProvider.session`) can fall back to it.
///
/// The real decision/file IO still happens in the background isolate; this state
/// is display-only. Its [ReceiveSessionState.responseHandler] is an unused,
/// empty controller because the decision travels to the isolate via
/// `sendDataToTask`, not through the in-process stream (controllers can't cross
/// isolates).
class BackgroundSessionState {
  /// The mirrored session (null when there is no active background transfer).
  final ReceiveSessionState? session;

  /// Whether the in-app accept/progress screen has already been pushed for the
  /// current [session]. Used by the tap-to-open path so a notification tap that
  /// wakes the app renders the screen exactly once.
  final bool shown;

  /// Whether [ProgressPage] is currently the active screen for this [session].
  /// The app has no [RouterinoObserver] wired up, so we can't read the live
  /// route stack; this flag makes progress-screen navigation idempotent (the
  /// resume/notification path and the in-app accept path share one navigator and
  /// must not double-push). Reset whenever a new session starts or the mirror is
  /// cleared.
  final bool progressShown;

  const BackgroundSessionState({
    required this.session,
    required this.shown,
    required this.progressShown,
  });

  const BackgroundSessionState.none()
      : session = null,
        shown = false,
        progressShown = false;
}

final backgroundSessionProvider = NotifierProvider<BackgroundSessionService, BackgroundSessionState>((ref) {
  return BackgroundSessionService();
});

class BackgroundSessionService extends PureNotifier<BackgroundSessionState> {
  @override
  BackgroundSessionState init() => const BackgroundSessionState.none();

  /// Convenience accessor for the current mirror session (display-only).
  ReceiveSessionState? get session => state.session;

  /// Stores the reconstructed [session] from an `incoming-request` event. Resets
  /// [BackgroundSessionState.shown] and [BackgroundSessionState.progressShown]
  /// so the tap-to-open path will render it fresh.
  void setSession(ReceiveSessionState session) {
    state = BackgroundSessionState(session: session, shown: false, progressShown: false);
  }

  /// Replaces the current mirror session in place (same id), e.g. after a
  /// `file-status` event flips a file to sending/finished/failed.
  void updateSession(ReceiveSessionState session) {
    state = BackgroundSessionState(session: session, shown: state.shown, progressShown: state.progressShown);
  }

  /// Marks the in-app screen as shown for the current session (called right
  /// after `ReceivePage`/`ProgressPage` is pushed).
  void markShown() {
    if (state.shown || state.session == null) {
      return;
    }
    state = BackgroundSessionState(session: state.session, shown: true, progressShown: state.progressShown);
  }

  /// Marks [ProgressPage] as the active screen for the current session. Implies
  /// [BackgroundSessionState.shown] (the user is past the accept screen).
  void markProgressShown() {
    if (state.session == null || (state.shown && state.progressShown)) {
      return;
    }
    state = BackgroundSessionState(session: state.session, shown: true, progressShown: true);
  }

  /// Clears the mirror (session canceled or no longer active).
  void clear() {
    state = const BackgroundSessionState.none();
  }
}
