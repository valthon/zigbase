/// Live-server test harness for the Dart SDK integration suite.
///
/// A direct port of `clients/typescript/test/integration/harness.ts`'s
/// server-launch mechanics: the binary path comes from `ZIGBASE_TEST_BINARY`
/// (the generic `zigbase` binary — runtime-created collections), a free
/// loopback port is acquired per attempt, the data dir is a fresh tempdir,
/// the superuser is bootstrapped via the `superuser create` CLI subcommand,
/// the server is launched with `--insecure-cookies`, and readiness is a poll
/// on `/api/health`. On start failure (e.g. a port collision that makes the
/// zap listener exit) it retries on a fresh port. `stop()` SIGTERMs the child
/// and removes the tempdir.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

/// Number of times to retry a failed server start (fresh port each attempt).
const int _startAttempts = 5;

/// A launched, healthy test server plus the superuser seeded into it.
class TestServer {
  final String baseUrl;
  final String superuserEmail;
  final String superuserPassword;
  final Process _process;
  final Directory _dataDir;
  bool _stopped = false;

  TestServer._(
    this.baseUrl,
    this.superuserEmail,
    this.superuserPassword,
    this._process,
    this._dataDir,
  );

  /// SIGTERM the server and remove its tempdir. Idempotent.
  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    _process.kill(ProcessSignal.sigterm);
    try {
      await _process.exitCode.timeout(const Duration(seconds: 5));
    } on TimeoutException {
      _process.kill(ProcessSignal.sigkill);
    }
    try {
      if (_dataDir.existsSync()) _dataDir.deleteSync(recursive: true);
    } catch (_) {
      // best-effort cleanup
    }
  }
}

/// The `zigbase` binary under test, supplied via `ZIGBASE_TEST_BINARY`.
/// Callers guard on this being non-null before invoking [startServer].
String get binaryPath => Platform.environment['ZIGBASE_TEST_BINARY']!;

/// The `dating-server` binary (the dating fixture compiled as a runnable
/// server, schema baked in), supplied via `ZIGBASE_TEST_DATING_BINARY`. Used by
/// the typed-tier e2e; callers guard on it being set before launching.
String? get datingBinaryPath =>
    Platform.environment['ZIGBASE_TEST_DATING_BINARY'];

/// Ask the OS for a free loopback TCP port (bind :0, read it, release). The
/// retry loop in [startServer] is the real guarantee against a lost race.
Future<int> _freePort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}

/// Poll `GET <url>/api/health` until it answers 200, or the child exits first
/// (surfaced immediately so a port-bind failure doesn't wait out the deadline).
Future<void> _waitForHealthOrExit(
  String url,
  Process proc, {
  Duration timeout = const Duration(seconds: 20),
}) async {
  var exited = false;
  Object? exitInfo;
  unawaited(proc.exitCode.then((code) {
    exited = true;
    exitInfo = 'server exited before becoming healthy (code=$code)';
  }));

  final deadline = DateTime.now().add(timeout);
  final client = http.Client();
  try {
    for (;;) {
      if (exited) throw StateError(exitInfo!.toString());
      try {
        final res = await client
            .get(Uri.parse('$url/api/health'))
            .timeout(const Duration(seconds: 2));
        if (res.statusCode == 200) return;
      } catch (_) {
        // not up yet
      }
      if (DateTime.now().isAfter(deadline)) {
        throw StateError('server did not become healthy within $timeout');
      }
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
  } finally {
    client.close();
  }
}

/// Launch the `zigbase` binary from `ZIGBASE_TEST_BINARY`: seed a superuser via
/// the CLI, start `serve --insecure-cookies` on a free port, and wait for
/// health. Retries on a fresh port when a start attempt fails.
Future<TestServer> startServer({
  String email = 'admin@test.local',
  String password = 'test-password-123',
  String? bin,
}) async {
  bin ??= binaryPath;
  Object? lastErr;

  for (var attempt = 1; attempt <= _startAttempts; attempt++) {
    final dataDir = Directory.systemTemp.createTempSync('zb-dart-it-');

    final su = await Process.run(bin, [
      'superuser',
      'create',
      '--email',
      email,
      '--password',
      password,
      '--data-dir',
      dataDir.path,
    ]);
    if (su.exitCode != 0) {
      try {
        dataDir.deleteSync(recursive: true);
      } catch (_) {}
      throw StateError(
          'superuser create failed (exit ${su.exitCode}): ${su.stderr}');
    }

    final port = await _freePort();
    final proc = await Process.start(bin, [
      'serve',
      '--http-port',
      '$port',
      '--data-dir',
      dataDir.path,
      '--insecure-cookies',
    ]);
    // Drain child stdio so its pipes never fill and stall the process.
    proc.stdout.drain<void>();
    proc.stderr.drain<void>();

    final url = 'http://127.0.0.1:$port';
    try {
      await _waitForHealthOrExit(url, proc);
      return TestServer._(url, email, password, proc, dataDir);
    } catch (err) {
      lastErr = err;
      proc.kill(ProcessSignal.sigkill);
      try {
        dataDir.deleteSync(recursive: true);
      } catch (_) {}
    }
  }

  throw StateError(
      'server did not start after $_startAttempts attempts; last error: $lastErr');
}

/// Authenticate as the seeded superuser and return the bearer token — used to
/// authorize the collection-provisioning calls the tests make directly.
Future<String> superuserToken(TestServer server) async {
  final res = await http.post(
    Uri.parse(
        '${server.baseUrl}/api/collections/_superusers/auth-with-password'),
    headers: {'content-type': 'application/json'},
    body: jsonEncode({
      'identity': server.superuserEmail,
      'password': server.superuserPassword
    }),
  );
  if (res.statusCode != 200) {
    throw StateError('superuser auth failed: ${res.statusCode} ${res.body}');
  }
  return (jsonDecode(res.body) as Map<String, dynamic>)['token'] as String;
}

/// Create a collection via the superuser collections API.
Future<Map<String, dynamic>> createCollection(
  TestServer server,
  String token,
  Map<String, dynamic> definition,
) async {
  final res = await http.post(
    Uri.parse('${server.baseUrl}/api/collections'),
    headers: {
      'content-type': 'application/json',
      'authorization': 'Bearer $token',
    },
    body: jsonEncode(definition),
  );
  if (res.statusCode < 200 || res.statusCode >= 300) {
    throw StateError('create collection failed: ${res.statusCode} ${res.body}');
  }
  return jsonDecode(res.body) as Map<String, dynamic>;
}
