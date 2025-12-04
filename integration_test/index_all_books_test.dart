// Integration test: index all books found in app's BooksSource using available
// TXT fallbacks (bundled assets or emulator Documents/TxtBooks). This avoids
// relying on pdf_render APIs that differ between patched versions.
// ignore_for_file: avoid_print

import 'dart:io';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:tasha/services/vector_db.dart';

Future<String?> _loadTxtFallback(String base) async {
  // Try bundled asset first
  try {
    final asset = 'assets/txt_books/$base.txt';
    final s = await rootBundle.loadString(asset);
    if (s.trim().isNotEmpty) return s;
  } catch (_) {}

  // Then try emulator/app Documents/TxtBooks folder
  try {
    final txtPath = '/data/user/0/com.example.tasha/app_flutter/TxtBooks/$base.txt';
    final f = File(txtPath);
    if (await f.exists()) return await f.readAsString();
  } catch (_) {}

  return null;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Index all BooksSource files (TXT fallbacks only)', (WidgetTester tester) async {
    final booksDir = Directory('/data/user/0/com.example.tasha/app_flutter/BooksSource');
    print('[TEST] BooksSource path: ${booksDir.path}');
    if (!await booksDir.exists()) {
      print('[TEST] BooksSource directory not found; ensure files are present on emulator');
      return;
    }

    final files = booksDir.listSync().whereType<File>().where((f) {
      final ext = p.extension(f.path).toLowerCase();
      return ext == '.pdf' || ext == '.txt';
    }).toList();
    print('[TEST] Found ${files.length} files');

    for (var f in files) {
      final base = p.basenameWithoutExtension(f.path);
      final bookId = p.basename(f.path);
      print('[TEST] Processing: $bookId');
      try {
        String? fullText = await _loadTxtFallback(base);

        if (fullText == null || fullText.trim().isEmpty) {
          print('[TEST] No TXT fallback for $bookId — skipping PDF extraction in this test');
          continue;
        }

        final inserted = await VectorDB.indexTextForBook(bookId, fullText, embedder: null, chunkSize: 1000);
        print('[TEST] Indexed $bookId inserted=$inserted chunks');
      } catch (e, st) {
        print('[TEST] Error processing ${f.path}: $e\n$st');
      }
    }

    print('[TEST] Index-all finished');
  }, timeout: Timeout(Duration(minutes: 10)));
}
