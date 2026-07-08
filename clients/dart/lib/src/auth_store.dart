import 'dart:async';
import 'dart:convert';

import 'jwt.dart';

/// Emitted on [AuthStore.onChange] after every [AuthStore.save] or
/// [AuthStore.clear].
class AuthEvent {
  final String? token;
  final Map<String, dynamic>? record;

  const AuthEvent(this.token, this.record);
}

/// Holds the current auth token/record, exposes [isValid], and notifies
/// listeners of changes via [onChange].
///
/// This class carries the default (in-memory) implementation shared by
/// [MemoryAuthStore] and [AsyncAuthStore]; subclasses override [save] and
/// [clear] to layer in persistence.
abstract class AuthStore {
  String? _token;
  Map<String, dynamic>? _record;
  final StreamController<AuthEvent> _controller =
      StreamController<AuthEvent>.broadcast();

  String? get token => _token;

  Map<String, dynamic>? get record => _record;

  /// `true` when [token] is present and not expired.
  bool get isValid => _token != null && !isTokenExpired(_token!);

  /// Broadcast stream; emits an [AuthEvent] after every [save] or [clear].
  Stream<AuthEvent> get onChange => _controller.stream;

  void save(String token, Map<String, dynamic>? record) {
    _token = token;
    _record = record;
    _emit();
  }

  void clear() {
    _token = null;
    _record = null;
    _emit();
  }

  /// Closes the underlying stream controller. Call when the store is no
  /// longer needed. After dispose, [save] and [clear] still update the
  /// in-memory state but no longer emit on [onChange].
  void dispose() {
    _controller.close();
  }

  void _emit() {
    if (_controller.isClosed) return;
    _controller.add(AuthEvent(_token, _record));
  }
}

/// A plain in-memory [AuthStore] with no persistence.
class MemoryAuthStore extends AuthStore {
  MemoryAuthStore();
}

/// An [AuthStore] that persists via caller-supplied async callbacks, so a
/// Flutter app can plug in `shared_preferences` (or any other storage)
/// without the SDK depending on Flutter.
///
/// Persists `'{"token":...,"record":...}'` JSON via [save] on every change,
/// calls [clear] (or `save('')` when no [clear] callback is given) on
/// [AuthStore.clear], and rehydrates synchronously from [initial] JSON. Each
/// persistence call is fire-and-forget but chained after the previous one,
/// so writes are applied in order and never interleave.
///
/// A persistence callback that throws is swallowed: the failed write is
/// dropped, later writes still run, and no unhandled async error is raised.
/// Callbacks that need failure visibility should handle (e.g. log) errors
/// themselves.
class AsyncAuthStore extends AuthStore {
  final Future<void> Function(String data) _save;
  final Future<void> Function()? _clear;
  Future<void> _pending = Future<void>.value();

  AsyncAuthStore({
    required Future<void> Function(String data) save,
    Future<void> Function()? clear,
    String? initial,
  })  : _save = save,
        _clear = clear {
    _rehydrate(initial);
  }

  void _rehydrate(String? initial) {
    if (initial == null || initial.isEmpty) return;
    try {
      final decoded = jsonDecode(initial);
      if (decoded is! Map) return;
      final token = decoded['token'];
      if (token is! String) return;
      final record = decoded['record'];
      _token = token;
      _record = record is Map<String, dynamic> ? record : null;
    } catch (_) {
      // Ignore malformed/corrupt initial data.
    }
  }

  @override
  void save(String token, Map<String, dynamic>? record) {
    super.save(token, record);
    _enqueue(() => _save(jsonEncode({'token': token, 'record': record})));
  }

  @override
  void clear() {
    super.clear();
    _enqueue(() => _clear != null ? _clear() : _save(''));
  }

  void _enqueue(Future<void> Function() op) {
    // Swallow per-op errors so one failed write neither breaks the chain
    // for later writes nor surfaces as an unhandled async error.
    _pending = _pending.then((_) => op()).catchError((Object _) {});
  }
}
