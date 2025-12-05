import 'package:flutter/material.dart';
import '../services/vector_db.dart';
import '../services/firebase_sync.dart';

class DebugQaListPage extends StatefulWidget {
  const DebugQaListPage({super.key});

  @override
  State<DebugQaListPage> createState() => _DebugQaListPageState();
}

class _DebugQaListPageState extends State<DebugQaListPage> {
  List<Map<String, dynamic>> _rows = [];
  bool _loading = false;
  String _status = '';

  @override
  void initState() {
    super.initState();
    _loadRows();
  }

  Future<void> _loadRows() async {
    setState(() {
      _loading = true;
      _status = 'Loading...';
    });
    try {
      final db = await VectorDB.openDb();
      final rows = await db.rawQuery('SELECT id, book, question, answer, unsynced FROM qa_pairs ORDER BY id DESC LIMIT 200');
      setState(() {
        _rows = rows;
        _status = 'Loaded ${rows.length} rows';
      });
    } catch (e) {
      setState(() {
        _status = 'Error: $e';
      });
    } finally {
      setState(() => _loading = false);
    }
  }

  Future<void> _doSync() async {
    setState(() {
      _status = 'Syncing...';
    });
    try {
      final sync = FirebaseSync('https://tashahit400-default-rtdb.asia-southeast1.firebasedatabase.app/');
      await sync.syncAll();
      setState(() {
        _status = 'Sync completed';
      });
      await _loadRows();
    } catch (e) {
      setState(() {
        _status = 'Sync failed: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Debug QA List'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadRows,
            tooltip: 'Reload',
          ),
          IconButton(
            icon: const Icon(Icons.sync),
            onPressed: _doSync,
            tooltip: 'Sync now',
          )
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: Text(_status),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : ListView.builder(
                    itemCount: _rows.length,
                    itemBuilder: (_, i) {
                      final r = _rows[i];
                      return ListTile(
                        title: Text(r['question']?.toString() ?? ''),
                        subtitle: Text((r['answer'] ?? '').toString(), maxLines: 3, overflow: TextOverflow.ellipsis),
                        trailing: r['unsynced'] == 1 ? const Icon(Icons.cloud_upload, color: Colors.orange) : const Icon(Icons.cloud_done, color: Colors.green),
                        onTap: () {
                          showDialog(context: context, builder: (ctx) => AlertDialog(
                            title: Text('QA #${r['id']}'),
                            content: SingleChildScrollView(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('Book: ${r['book'] ?? ''}'), const SizedBox(height:8), Text('Question:\n${r['question'] ?? ''}'), const SizedBox(height:12), Text('Answer:\n${r['answer'] ?? ''}')],)),
                            actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close'))],
                          ));
                        },
                      );
                    },
                  ),
          )
        ],
      ),
    );
  }
}
