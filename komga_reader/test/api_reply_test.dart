// Komga's replies are read to the end, even when nothing in them is used (code review 2026-10-05, #7): an unread reply
// keeps its connection from being used again, and a reading session's progress saves piled up sockets.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:komga_reader/api.dart';

/// Answers every request with a short reply, noting whether anything read it.
class _Watching extends http.BaseClient {
  int replies = 0, drained = 0;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    replies++;
    final body = StreamController<List<int>>(onListen: () => drained++);
    body.add('{}'.codeUnits);
    unawaited(body.close());
    return http.StreamedResponse(body.stream, 200);
  }
}

void main() {
  test("a page save's reply is read, so its connection can be used again", () async {
    final client = _Watching();
    final api = http.runWithClient(() => Komga('http://test', 'k'), () => client);
    await api.setProgress('B1', 3);
    await api.putClientSetting('komgareader.pins', '[]');
    expect(client.replies, 2);
    expect(client.drained, 2, reason: 'every reply read to the end');
  });
}
