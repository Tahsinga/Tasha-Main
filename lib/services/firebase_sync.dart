// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:sqflite/sqflite.dart';
import 'vector_db.dart';

class FirebaseSync {
  final String baseUrl; // should be like https://<project>.firebaseio.com or the provided URL (must include .json when used)

  FirebaseSync(this.baseUrl);

  // Process-wide guard to prevent concurrent uploads from multiple FirebaseSync
  // instances. This avoids duplicate POSTs when multiple callers invoke
  // `uploadUnsynced()` around the same time (e.g. auto-timer + manual sync).
  static bool _uploadInProgress = false;

  String _ensureBase(String path) {
    var b = baseUrl;
    if (b.endsWith('/')) b = b.substring(0, b.length - 1);
    if (!path.startsWith('/')) path = '/$path';
    return '$b$path';
  }

  Future<void> init() async {
    // Ensure local helper tables exist; use the same DB used by VectorDB
    final db = await VectorDB.openDb();
    await db.execute('''
      CREATE TABLE IF NOT EXISTS remote_sync (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        local_qa_id INTEGER UNIQUE,
        firebase_id TEXT UNIQUE,
        synced INTEGER DEFAULT 0,
        timestamp TEXT
      );
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS sync_meta (
        key TEXT PRIMARY KEY,
        value TEXT
      );
    ''');
  }

  Future<String> _getDeviceId() async {
    final prefs = await SharedPreferences.getInstance();
    var id = prefs.getString('device_id');
    if (id == null || id.isEmpty) {
      final host = Platform.localHostname;
      final hostSafe = host.isNotEmpty ? host : 'unknown';
      id = DateTime.now().millisecondsSinceEpoch.toString() + '-' + hostSafe;
      await prefs.setString('device_id', id);
    }
    return id;
  }

  Future<DateTime?> _getLastSyncTime() async {
    final db = await VectorDB.openDb();
    final rows = await db.query('sync_meta', where: 'key = ?', whereArgs: ['last_sync_time']);
    if (rows.isEmpty) return null;
    final v = rows.first['value'] as String?;
    if (v == null) return null;
    try {
      return DateTime.parse(v);
    } catch (_) {
      return null;
    }
  }

  Future<void> _setLastSyncTime(DateTime t) async {
    final db = await VectorDB.openDb();
    await db.insert('sync_meta', {'key': 'last_sync_time', 'value': t.toUtc().toIso8601String()}, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<Map<String, dynamic>>> _getUnsyncedLocalQa() async {
    final db = await VectorDB.openDb();
    // left join qa_pairs with remote_sync to find entries without firebase_id
    final rows = await db.rawQuery('''
      SELECT q.id as local_id, q.book, q.question, q.answer, q.question_embedding
      FROM qa_pairs q
      LEFT JOIN remote_sync r ON r.local_qa_id = q.id
      WHERE r.firebase_id IS NULL
      ORDER BY q.id ASC
    ''');
    return rows;
  }

  Future<int> uploadUnsynced() async {
    if (_uploadInProgress) {
      print('[FirebaseSync] uploadUnsynced skipped: already in progress');
      return 0;
    }
    _uploadInProgress = true;
    try {
      final unsynced = await _getUnsyncedLocalQa();
      if (unsynced.isEmpty) return 0;
      final deviceId = await _getDeviceId();
      var uploaded = 0;
      for (var row in unsynced) {
        try {
          final entry = {
            'question': row['question'] ?? '',
            'answer': row['answer'] ?? '',
            'book': row['book'] ?? '',
            'timestamp': DateTime.now().toUtc().toIso8601String(),
            'deviceId': deviceId,
          };
          final url = _ensureBase('/knowledgeBase.json');
          final resp = await http.post(Uri.parse(url), headers: {'Content-Type': 'application/json'}, body: jsonEncode(entry)).timeout(const Duration(seconds: 15));
          if (resp.statusCode == 200) {
            final parsed = jsonDecode(resp.body) as Map<String, dynamic>;
            final firebaseId = parsed['name'] as String?;
            if (firebaseId != null) {
              final db = await VectorDB.openDb();
              await db.insert('remote_sync', {'local_qa_id': row['local_id'], 'firebase_id': firebaseId, 'synced': 1, 'timestamp': DateTime.now().toUtc().toIso8601String()});
              uploaded++;
            }
          } else {
            print('[FirebaseSync] upload failed code=${resp.statusCode} body=${resp.body}');
          }
        } catch (e) {
          print('[FirebaseSync] upload exception: $e');
        }
      }
      return uploaded;
    } finally {
      _uploadInProgress = false;
    }
  }

  // Public helper: number of unsynced local QA entries
  Future<int> getUnsyncedCount() async {
    final unsynced = await _getUnsyncedLocalQa();
    return unsynced.length;
  }

  Future<void> downloadAndMerge() async {
    final url = _ensureBase('/knowledgeBase.json');
    try {
      final resp = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 15));
      if (resp.statusCode != 200) {
        print('[FirebaseSync] download failed status=${resp.statusCode}');
        return;
      }
      final Map<String, dynamic>? data = jsonDecode(resp.body) as Map<String, dynamic>?;
      if (data == null) return;
      final db = await VectorDB.openDb();
      final lastSync = await _getLastSyncTime();
      final existingRemote = await db.rawQuery('SELECT firebase_id FROM remote_sync');
      final existingSet = <String>{};
      for (var r in existingRemote) {
        final fid = r['firebase_id'] as String?;
        if (fid != null) existingSet.add(fid);
      }

      for (var key in data.keys) {
        try {
          if (existingSet.contains(key)) continue; // already merged
          final entry = data[key] as Map<String, dynamic>;
          final tsStr = (entry['timestamp'] as String?) ?? '';
          DateTime? ts;
          try { ts = DateTime.parse(tsStr); } catch (_) { ts = null; }
          if (lastSync != null && ts != null && !ts.isAfter(lastSync)) {
            // older or equal — skip
            // still ensure remote_sync mapping exists to avoid reprocessing
            await db.insert('remote_sync', {'local_qa_id': null, 'firebase_id': key, 'synced': 1, 'timestamp': ts.toUtc().toIso8601String()}, conflictAlgorithm: ConflictAlgorithm.replace);
            continue;
          }

          final question = (entry['question'] ?? '').toString();
          final answer = (entry['answer'] ?? '').toString();
          final book = (entry['book'] ?? '').toString();

          if (question.trim().isEmpty || answer.trim().isEmpty) {
            // create mapping to avoid repeated attempts
            await db.insert('remote_sync', {'local_qa_id': null, 'firebase_id': key, 'synced': 1, 'timestamp': ts?.toUtc().toIso8601String() ?? DateTime.now().toUtc().toIso8601String()}, conflictAlgorithm: ConflictAlgorithm.replace);
            continue;
          }

          // Heuristic duplicate check: exact text match in questions
          final matches = await VectorDB.searchQaPairsByText(question, book: book, topK: 10);
          var isDup = false;
          for (var m in matches) {
            final q = (m['question'] ?? '').toString();
            if (q.trim().toLowerCase() == question.trim().toLowerCase()) {
              isDup = true;
              break;
            }
          }
          if (!isDup) {
            final localId = await VectorDB.insertQaPair(book, question, answer, null);
            await db.insert('remote_sync', {'local_qa_id': localId, 'firebase_id': key, 'synced': 1, 'timestamp': ts?.toUtc().toIso8601String() ?? DateTime.now().toUtc().toIso8601String()}, conflictAlgorithm: ConflictAlgorithm.replace);
          } else {
            // just record mapping using null local_qa_id to mark we saw it
            await db.insert('remote_sync', {'local_qa_id': null, 'firebase_id': key, 'synced': 1, 'timestamp': ts?.toUtc().toIso8601String() ?? DateTime.now().toUtc().toIso8601String()}, conflictAlgorithm: ConflictAlgorithm.replace);
          }
        } catch (e) {
          print('[FirebaseSync] merge entry error for key=$key: $e');
        }
      }
      await _setLastSyncTime(DateTime.now().toUtc());
    } catch (e) {
      print('[FirebaseSync] download exception: $e');
    }
  }

  Future<void> syncAll() async {
    await init();
    try {
      // quick online check
      final res = await InternetAddress.lookup('example.com').timeout(const Duration(seconds: 4));
      if (res.isEmpty) return;
    } catch (_) {
      print('[FirebaseSync] offline - skip sync');
      return;
    }
    try {
      await uploadUnsynced();
      await downloadAndMerge();
      print('[FirebaseSync] syncAll completed');
    } catch (e) {
      print('[FirebaseSync] syncAll error: $e');
    }
  }
}
