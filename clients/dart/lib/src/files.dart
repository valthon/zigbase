/// File URL construction + the file-access token endpoint.
///
/// A byte-for-byte port of `FilesService` in `clients/typescript/src/files.ts`:
/// same URL shape (`<baseUrl>/api/files/<col>/<rec>/<filename>`, each segment
/// `encodeURIComponent`-ed — `Uri.encodeComponent` in Dart), same query keys
/// (`download=1`, `thumb=<spec>`, `token=<t>`), same `POST /api/files/token`
/// envelope (`{token}`, `src/api/files.zig`).
library;

import 'records.dart';
import 'transport.dart';

class FilesService {
  final Transport _transport;
  final String _baseUrl;

  FilesService(Transport transport, String baseUrl)
      : _transport = transport,
        _baseUrl = baseUrl;

  /// Build a file URL for [record] + [filename]. The collection is taken from
  /// `record.data['collectionId']`, falling back to `record.data['collectionName']`;
  /// throws [ArgumentError] when neither is present.
  String getUrl(
    ZbRecord record,
    String filename, {
    bool download = false,
    String? thumb,
    String? token,
  }) {
    final col =
        record.getString('collectionId') ?? record.getString('collectionName');
    if (col == null) {
      throw ArgumentError(
          'record has neither collectionId nor collectionName; cannot build a file URL');
    }
    return getUrlFor(col, record.id, filename,
        download: download, thumb: thumb, token: token);
  }

  /// Build a file URL from explicit `(collectionIdOrName, recordId, filename)`.
  /// Every path segment is individually `Uri.encodeComponent`-ed.
  String getUrlFor(
    String collectionIdOrName,
    String recordId,
    String filename, {
    bool download = false,
    String? thumb,
    String? token,
  }) {
    final base = _baseUrl.replaceAll(RegExp(r'/+$'), '');
    final path = '$base/api/files/'
        '${Uri.encodeComponent(collectionIdOrName)}/'
        '${Uri.encodeComponent(recordId)}/'
        '${Uri.encodeComponent(filename)}';

    final query = <String, String>{};
    if (download) query['download'] = '1';
    if (thumb != null) query['thumb'] = thumb;
    if (token != null) query['token'] = token;
    if (query.isEmpty) return path;

    return Uri.parse(path).replace(queryParameters: query).toString();
  }

  /// `POST /api/files/token` — mints a short-lived file-access token for
  /// embedding protected files (e.g. in an `<img>` tag).
  Future<String> getToken() async {
    final res = await _transport.send('/api/files/token', method: 'POST')
        as Map<String, dynamic>;
    return res['token'] as String;
  }
}
