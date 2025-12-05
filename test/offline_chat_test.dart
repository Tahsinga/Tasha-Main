// Simple local test to verify offline chat list sorting works
// Run with: flutter test test/offline_chat_test.dart

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Offline Chat Tests', () {
    test('Immutable list from DB can be converted to mutable and sorted', () {
      // Simulate what SQLite returns: a list of maps (immutable)
      final immutableChunks = const [
        {'text': 'Short', 'start_page': 1},
        {'text': 'This is a much longer text that should come first when sorted by length', 'start_page': 2},
        {'text': 'Medium length text here', 'start_page': 3},
      ];

      // This would fail with "Unsupported operation: read-only" if we tried:
      // immutableChunks.sort((a, b) => ...);

      // But converting to mutable list works:
      var chunks = List<Map<String, dynamic>>.from(immutableChunks);
      
      // Now sorting should work without error
      chunks.sort((a, b) {
        final ta = (a['text'] ?? '').toString();
        final tb = (b['text'] ?? '').toString();
        return tb.length.compareTo(ta.length);
      });

      // Verify sort order (longest first)
      expect(chunks[0]['text'], contains('much longer text'));
      expect(chunks[1]['text'], contains('Medium length'));
      expect(chunks[2]['text'], 'Short');

      print('✓ Sorting test passed: list was converted to mutable and sorted correctly');
    });

    test('Empty list handling works', () {
      final emptyChunks = <Map<String, dynamic>>[];
      var chunks = List<Map<String, dynamic>>.from(emptyChunks);
      
      expect(chunks.isEmpty, true);
      
      print('✓ Empty list test passed');
    });

    test('Null/missing text fields are handled gracefully', () {
      final chunksWithNulls = [
        {'text': null, 'start_page': 1},
        {'text': 'Normal text', 'start_page': 2},
        {}, // missing 'text' key entirely
      ];

      var chunks = List<Map<String, dynamic>>.from(chunksWithNulls);
      
      // Should not throw when sorting with defensive access
      chunks.sort((a, b) {
        final ta = (a['text'] ?? '').toString();
        final tb = (b['text'] ?? '').toString();
        return tb.length.compareTo(ta.length);
      });

      expect(chunks.length, 3);
      print('✓ Null handling test passed');
    });
  });
}
