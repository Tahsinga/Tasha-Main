import 'package:flutter/material.dart';
import '../services/vector_db.dart';
import '../main.dart' show HomePage, SettingsPage;
import 'package:path_provider/path_provider.dart' show getApplicationDocumentsDirectory;
import 'dart:io';
import 'package:intl/intl.dart' show DateFormat, TimeOfDay;

/// Optimized message tile to reduce rendering overhead
class _MessageTile extends StatelessWidget {
  final Map<String, dynamic> message;
  final bool isMe;
  final VoidCallback onViewSources;

  const _MessageTile({
    required this.message,
    required this.isMe,
    required this.onViewSources,
  });

  @override
  Widget build(BuildContext context) {
    final textVal = (message['text'] ?? '').toString();
    final isProcessing = message['from'] == 'bot' && message['status'] == 'processing';
    final bullets = (message['bullets'] ?? []) as List;
    final citations = (message['citations'] ?? []) as List;

    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 8),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.78,
          minHeight: isMe ? 0 : 60,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        decoration: BoxDecoration(
          color: isMe ? Colors.green[600] : Colors.white,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(12),
            topRight: const Radius.circular(12),
            bottomLeft: Radius.circular(isMe ? 12 : 0),
            bottomRight: Radius.circular(isMe ? 0 : 12),
          ),
          boxShadow: const [
            BoxShadow(
              color: Colors.black12,
              blurRadius: 4,
              offset: Offset(0, 2),
            )
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isProcessing)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 3),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      textVal,
                      style: TextStyle(
                        color: isMe ? Colors.white : Colors.black87,
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              )
            else
              Row(
                children: [
                  Expanded(
                    child: Text(
                      textVal,
                      style: TextStyle(
                        color: isMe ? Colors.white : Colors.black87,
                        fontSize: isMe ? 15 : 16,
                        height: 1.35,
                        fontWeight: isMe ? FontWeight.w500 : FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.purple[50],
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Text(
                      'Offline',
                      style: TextStyle(fontSize: 11, color: Colors.purple),
                    ),
                  )
                ],
              ),
            const SizedBox(height: 6),
            Text(
              message['time'] ?? '',
              style: TextStyle(
                color: isMe ? Colors.white70 : Colors.black45,
                fontSize: 11,
              ),
            ),
            if (bullets.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: List.generate(
                    bullets.length,
                    (i) => Padding(
                      padding: const EdgeInsets.only(bottom: 4.0),
                      child: Text(
                        '• ${bullets[i].toString()}',
                        style: TextStyle(
                          color: isMe ? Colors.white70 : Colors.black87,
                          fontSize: 13,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            if (citations.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6.0),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Sources: ${citations.map((c) => c['book'] ?? '').where((s) => s.isNotEmpty).toSet().join(', ')}',
                        style: TextStyle(
                          color: isMe ? Colors.white70 : Colors.black45,
                          fontSize: 12,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    TextButton(
                      onPressed: onViewSources,
                      child: const Text('View'),
                    )
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Standalone offline chat bot page that mirrors the online chat UI
class OfflineChatBotPage extends StatefulWidget {
  final String? selectedBook;

  const OfflineChatBotPage({super.key, this.selectedBook});

  @override
  State<OfflineChatBotPage> createState() => _OfflineChatBotPageState();
}

class _OfflineChatBotPageState extends State<OfflineChatBotPage> {
  final TextEditingController _messageController = TextEditingController();
  final List<Map<String, dynamic>> _messages = [];
  final ScrollController _scrollController = ScrollController();
  bool _isLoading = false;
  String? _selectedBook;
  int _lastMessageCount = 0;

  @override
  void initState() {
    super.initState();
    _selectedBook = widget.selectedBook;
  }

  @override
  void dispose() {
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    if (!_scrollController.hasClients) return;
    Future.microtask(() {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _askQuestion(String question) async {
    if (question.trim().isEmpty) return;

    final now = TimeOfDay.now().format(context);
    setState(() {
      _messages.add({'from': 'user', 'text': question, 'time': now});
      _lastMessageCount = _messages.length;
    });

    _scrollToBottom();

    // Insert processing placeholder
    setState(() {
      _messages.add({
        'from': 'bot',
        'text': 'Searching offline database...',
        'time': TimeOfDay.now().format(context),
        'status': 'processing'
      });
    });

    try {
      final q = question.trim().toLowerCase();
      String answer = '';
      List<Map<String, dynamic>> citations = [];
      List<String> bullets = [];
      bool isSummary = false;

      // Handle book selection queries
      if (q.contains('what book') ||
          q.contains('which book') ||
          q.contains('selected book')) {
        answer = _selectedBook ?? 'No book selected';
      }
      // Handle summary/describe queries
      else if (q.contains('summarize') ||
          q.contains('summary') ||
          q.contains('tell me about') ||
          q.contains('describe') ||
          q.contains('about this book')) {
        if (_selectedBook == null) {
          answer = 'Please select a book first to get a summary.\n\nTap the book icon to select one.';
        } else {
          try {
            var chunks = await VectorDB.chunksForBook(_selectedBook!);
            if (chunks.isEmpty) {
              answer = 'No content indexed for this book yet.\n\nTry indexing the book first.';
            } else {
              chunks = List<Map<String, dynamic>>.from(chunks);
              chunks.sort((a, b) {
                final ta = (a['text'] ?? '').toString();
                final tb = (b['text'] ?? '').toString();
                return tb.length.compareTo(ta.length);
              });

              final topChunks = chunks.take(5).toList();
              bullets = topChunks
                  .map((c) {
                    final text = (c['text'] ?? '').toString();
                    return text.length > 100 ? '${text.substring(0, 100)}...' : text;
                  })
                  .where((t) => t.isNotEmpty)
                  .take(3)
                  .toList();

              final buffer = StringBuffer();
              buffer.writeln('📖 Summary of $_selectedBook:\n');
              for (var chunk in topChunks) {
                try {
                  final text = (chunk['text'] ?? '').toString();
                  if (text.trim().isEmpty) continue;
                  buffer.writeln(text.length > 300 ? '${text.substring(0, 300)}...' : text);
                  buffer.writeln('');
                } catch (_) {}
              }
              answer = buffer.toString().trim();
              isSummary = true;
              citations = topChunks.take(3).map((c) {
                return {
                  'book': _selectedBook,
                  'source': 'chunk',
                  'text': (c['text'] ?? '').toString()
                };
              }).toList();
            }
          } catch (e) {
            print('[OfflineChat] Summary error: $e');
            answer = 'Error fetching summary: ${e.toString()}';
          }
        }
      }
      // Regular question answering
      else {
        try {
          final bookFilter = _selectedBook;
          final combinedQuery = (bookFilter != null) ? '[$bookFilter] $question' : question;
          final results = await VectorDB.answerQuery(combinedQuery, topK: 3, book: bookFilter);

          if (results.isEmpty) {
            answer = 'No answer found in offline database.\n\nTry:\n• Selecting a different book\n• Asking a different question\n• Indexing more books';
          } else {
            final bestResult = results.firstWhere(
              (r) => (r['answer'] ?? '').toString().trim().isNotEmpty,
              orElse: () => results.first,
            );

            answer = bestResult['answer'] ?? bestResult['text'] ?? '';

            citations = results.take(2).map((r) {
              return {
                'book': _selectedBook ?? 'Database',
                'source': r['source'] ?? 'chunk',
                'answer': r['answer'] ?? r['text'] ?? '',
                'question': r['question'] ?? ''
              };
            }).toList();

            if (answer.isNotEmpty) {
              bullets = answer
                  .split('\n')
                  .where((line) => line.trim().isNotEmpty)
                  .take(2)
                  .toList();
            }
          }
        } catch (e) {
          print('[OfflineChat] Query error: $e');
          answer = 'Error querying database: $e';
        }
      }

      // Replace processing message with actual result
      final processingIndex = _messages.lastIndexWhere(
          (m) => m['from'] == 'bot' && m['status'] == 'processing');
      if (processingIndex != -1) {
        setState(() {
          _messages[processingIndex] = {
            'from': 'bot',
            'text': answer,
            'time': TimeOfDay.now().format(context),
            'citations': citations,
            'bullets': bullets,
            'isSummary': isSummary,
          };
        });
      }

      _scrollToBottom();
    } catch (e) {
      print('[OfflineChat] Unexpected error: $e');
      final processingIndex = _messages.lastIndexWhere(
          (m) => m['from'] == 'bot' && m['status'] == 'processing');
      if (processingIndex != -1) {
        setState(() {
          _messages[processingIndex] = {
            'from': 'bot',
            'text': 'Unexpected error: $e',
            'time': TimeOfDay.now().format(context),
          };
        });
      }
    } finally {
      setState(() => _isLoading = false);
    }
  }

  void _handleSend() {
    final msg = _messageController.text.trim();
    if (msg.isEmpty) return;
    _messageController.clear();
    _askQuestion(msg);
  }

  Future<void> _selectBook() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final bookDir = Directory('${dir.path}/BooksSource');

      if (!await bookDir.exists()) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No books found in storage')),
        );
        return;
      }

      final files = bookDir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.toLowerCase().endsWith('.pdf'))
          .toList();

      if (!mounted) return;

      if (files.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No PDF books available')),
        );
        return;
      }

      // Show book picker
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Select a Book'),
          content: SizedBox(
            width: 300,
            child: ListView.builder(
              itemCount: files.length,
              itemBuilder: (_, i) {
                final fileName = files[i].path.split('/').last;
                return ListTile(
                  title: Text(fileName),
                  onTap: () {
                    setState(() => _selectedBook = fileName);
                    Navigator.pop(ctx);
                  },
                );
              },
            ),
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error selecting book: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        elevation: 0,
        title: const Text('Offline Chat'),
        actions: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Center(
              child: Row(
                children: [
                  const Icon(Icons.book, size: 18),
                  const SizedBox(width: 8),
                  Text(
                    _selectedBook ?? 'No book',
                    style: const TextStyle(fontSize: 12),
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    icon: const Icon(Icons.change_circle),
                    onPressed: _selectBook,
                    tooltip: 'Change book',
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          // Message area with optimized rendering
          Expanded(
            child: Container(
              color: Colors.grey[50],
              child: _messages.isEmpty
                  ? Center(
                      child: Text(
                        'Say hi 👋 — ask about the book',
                        style: TextStyle(color: Colors.grey[600]),
                      ),
                    )
                  : ListView.builder(
                      controller: _scrollController,
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
                      itemCount: _messages.length,
                      itemBuilder: (ctx, i) {
                        final m = _messages[i];
                        final isMe = m['from'] == 'user';
                        return _MessageTile(
                          message: m,
                          isMe: isMe,
                          onViewSources: () => _showSources(m['citations'] ?? []),
                        );
                      },
                    ),
            ),
          ),
          // Input bar
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            color: Colors.white,
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _messageController,
                    enabled: !_isLoading,
                    decoration: InputDecoration(
                      hintText: 'Type a message...',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(24),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                    ),
                    onSubmitted: (_) => _handleSend(),
                  ),
                ),
                const SizedBox(width: 8),
                CircleAvatar(
                  radius: 22,
                  backgroundColor: Colors.green[600],
                  child: IconButton(
                    icon: const Icon(Icons.send, color: Colors.white),
                    onPressed: _isLoading ? null : _handleSend,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      bottomNavigationBar: _buildFooter(),
    );
  }

  void _showSources(List citations) {
    if (citations.isEmpty) return;
    showDialog<void>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('Source excerpts'),
          content: SizedBox(
            width: 560,
            child: ListView.separated(
              shrinkWrap: true,
              itemCount: citations.length,
              separatorBuilder: (_, __) => const Divider(),
              itemBuilder: (c, idx) {
                final item = citations[idx] as Map<String, dynamic>;
                final book = item['book'] ?? 'Unknown';
                final source = item['source'] ?? '?';
                final excerpt = (item['answer'] ?? item['text'] ?? '').toString();
                return ListTile(
                  title: Text('$book — $source'),
                  subtitle: Text(
                    excerpt,
                    maxLines: 6,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onTap: () => Navigator.pop(ctx),
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Close'),
            )
          ],
        );
      },
    );
  }

  Widget _buildFooter() {
    return Container(
      decoration: BoxDecoration(
        boxShadow: [
          BoxShadow(
            color: const Color.fromRGBO(158, 158, 158, 0.2),
            blurRadius: 10,
            offset: const Offset(0, -5),
          ),
        ],
      ),
      child: NavigationBar(
        selectedIndex: 0,
        onDestinationSelected: (index) {
          if (index == 0) {
            Navigator.of(context).pushAndRemoveUntil(
                MaterialPageRoute(builder: (_) => HomePage(initialIndex: 0)),
                (route) => false);
            return;
          }
          if (index == 1) {
            Navigator.of(context).pushAndRemoveUntil(
                MaterialPageRoute(builder: (_) => HomePage(initialIndex: 1)),
                (route) => false);
            return;
          }
          Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const SettingsPage()));
        },
        backgroundColor: Colors.white,
        height: 70,
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.library_books_outlined),
            selectedIcon: Icon(Icons.library_books),
            label: 'Library',
          ),
          NavigationDestination(
            icon: Icon(Icons.update_outlined),
            selectedIcon: Icon(Icons.update),
            label: 'Updates',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: 'Settings',
          ),
        ],
      ),
    );
  }
}
