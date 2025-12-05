// lib/main.dart
// ignore_for_file: unnecessary_type_check, no_leading_underscores_for_local_identifiers, unused_element, unused_local_variable, unnecessary_null_comparison, unused_import, unnecessary_cast

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' show min;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:pdf_render/pdf_render.dart' as pdf_render;
import 'package:pdfx/pdfx.dart' as pdfx;
import 'package:shared_preferences/shared_preferences.dart';
import 'services/tasha_utils.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';
import 'package:syncfusion_flutter_pdfviewer/pdfviewer.dart';

import 'services/backend_client.dart';
import 'services/backend_config.dart';
import 'services/embedding_service.dart';
import 'services/firebase_sync.dart';
import 'services/index_worker.dart';
import 'services/ocr_worker.dart';
import 'services/rag_service.dart';
import 'services/vector_db.dart';
import 'ui/chunks_viewer.dart';
import 'ui/offline_chat_bot.dart';
import 'ui/debug_qa_list.dart';

void main() {
  runApp(const MyApp());
}

// Utility: return filename without path and without a trailing .pdf extension (case-insensitive)
String _stripPdfExt(String pathOrName) {
  try {
    final name = pathOrName.split(Platform.pathSeparator).last;
    if (name.toLowerCase().endsWith('.pdf')) {
      return name.substring(0, name.length - 4);
    }
    return name;
  } catch (_) {
    return pathOrName;
  }
}

// Server domain settings card: save the backend domain used for fetching assets
class _ServerSettingsCard extends StatefulWidget {
  @override
  State<_ServerSettingsCard> createState() => _ServerSettingsCardState();
}

class _ServerSettingsCardState extends State<_ServerSettingsCard> {
  final TextEditingController _ctrl = TextEditingController();
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _ctrl.text = prefs.getString('SERVER_DOMAIN') ?? '';
      setState(() {});
    } catch (_) {}
  }

  Future<void> _save() async {
    setState(() => _loading = true);
    try {
      final prefs = await SharedPreferences.getInstance();
      final v = _ctrl.text.trim();
      await prefs.setString('SERVER_DOMAIN', v);
      // Also store as OPENAI_PROXY_URL for compatibility with proxy usage
      await prefs.setString('OPENAI_PROXY_URL', v);
      // ignore: use_build_context_synchronously
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Server domain saved')));
    } catch (e) {
      // ignore: use_build_context_synchronously
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Save failed: $e')));
    } finally {
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
                Text('Server / Backend',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
              const SizedBox(height: 10),
              TextField(
                controller: _ctrl,
                decoration: InputDecoration(
                    hintText: 'https://your-server.example.com',
                    suffixIcon: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                              icon: const Icon(Icons.save), onPressed: _save)
                        ])),
              ),
              const SizedBox(height: 8),
              Text(
                  'Enter the base domain or URL of your bookuploader server. Example: https://192.168.1.5:8000 or https://example.com',
                  style: TextStyle(
                      color: Colors.grey[600], fontSize: 12)),
              const SizedBox(height: 8),
              Row(children: [
                ElevatedButton(
                    onPressed: _save,
                    child: _loading
                        ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                        : const Text('Save'))
              ]),
            ]),
      ),
    );
  }
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'E-Book Library',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF0B5394),
          brightness: Brightness.light,
        ),
        textTheme: const TextTheme(
          titleLarge: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
          titleMedium: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          bodyLarge: TextStyle(fontSize: 14, color: Colors.black87),
          bodyMedium: TextStyle(fontSize: 13, color: Colors.black54),
          bodySmall: TextStyle(fontSize: 12, color: Colors.black54),
          labelLarge: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
        appBarTheme: const AppBarTheme(
          titleTextStyle: TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: Colors.black),
          foregroundColor: Colors.black,
          backgroundColor: Colors.white,
          elevation: 0,
          centerTitle: false,
        ),
      ),
      home: const HomePage(),
    );
  }
}

// Reusable footer navigation used across pages. If `onDestinationSelected` is
// provided it will be used, otherwise default navigation behavior is applied.
class AppFooter extends StatelessWidget {
  final int selectedIndex;
  final ValueChanged<int>? onDestinationSelected;

  const AppFooter({super.key, this.selectedIndex = 0, this.onDestinationSelected});

  @override
  Widget build(BuildContext context) {
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
        selectedIndex: selectedIndex,
        onDestinationSelected: (index) {
          if (onDestinationSelected != null) {
            onDestinationSelected!(index);
            return;
          }

          // Default navigation behaviour: replace stack with HomePage when
          // switching to Library/Updates, or push Settings page when selected.
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
          // index == 2 => Settings
          Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SettingsPage()));
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

class HomePage extends StatefulWidget {
  final int initialIndex;
  const HomePage({super.key, this.initialIndex = 0});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final TextEditingController _searchController = TextEditingController();
  List<File> _allBooks = [];
  List<File> _filteredBooks = [];
  int _currentIndex = 0;
  final Set<String> _bookmarks = {};
  File? _activeBook;
  late PdfViewerController _pdfController;
  bool _pdfBookmarked = false;
  bool _isPdfLoading = false;
  bool _isOpening = false;
  // Queue to serialize book open requests so only one open runs at a time.
  final List<File> _openQueue = [];
  bool _processingOpenQueue = false;
  bool _isIndexing = false;
  bool _indexingCancelled = false;
  int _indexDone = 0;
  int _indexTotal = 0;
  // Auto-sync timer and guard
  Timer? _autoSyncTimer;
  bool _syncInProgress = false;

  // Per-book cover images will be used from assets/images/<bookname_no_ext>.png
  // If an image is missing, a neutral placeholder will be shown.

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
    _pdfController = PdfViewerController();
    _searchController.addListener(_onSearchChanged);
    // Load books and ensure UI updates after they're loaded
    _loadBooks().then((_) {
      if (mounted) {
        setState(() {
          // Force rebuild after books are loaded
        });
      }
    });
    // Attempt a background sync of offline QA to central Firebase when online
        Future.microtask(() async {
      try {
        final sync = FirebaseSync(
            'https://tashahit400-default-rtdb.asia-southeast1.firebasedatabase.app/');
        await sync.syncAll();
        // Start an auto-upload timer that attempts to upload unsynced entries every 1 second
        _autoSyncTimer = Timer.periodic(const Duration(seconds: 1), (t) async {
          if (_syncInProgress) return;
          _syncInProgress = true;
          try {
            await sync.uploadUnsynced();
          } catch (e) {
            print('[HomePage] auto-upload error: $e');
          } finally {
            _syncInProgress = false;
          }
        });
      } catch (e) {
        print('[HomePage] firebase sync failed: $e');
      }
    });
  }

  void _onSearchChanged() {
    final query = _searchController.text.toLowerCase();
    setState(() {
      if (query.isEmpty) {
        _filteredBooks = List.from(_allBooks);
      } else {
        _filteredBooks = _allBooks
            .where((b) => b.path
            .split(Platform.pathSeparator)
            .last
            .toLowerCase()
            .contains(query))
            .toList();
      }
    });
  }

  /// Loads PDFs from application documents /BooksSource.
  /// If the folder doesn't exist, this routine attempts to copy
  /// from bundled assets listed below (only if those assets are present
  /// and declared in pubspec.yaml). If you don't have those assets,
  /// either add them or remove the copy block.
  Future<void> _loadBooks() async {
    // Simplified deterministic implementation:
    // 1) Ensure app documents BooksSource folder exists.
    // 2) Copy every PDF asset under assets/BooksSource into that folder (if not already copied).
    // 3) List PDFs from the documents folder and populate the library lists.
    print('[LoadBooks] Starting _loadBooks');
    final Directory appDir = await getApplicationDocumentsDirectory();
    print('[LoadBooks] App documents dir: ${appDir.path}');
    final pdfDir = Directory('${appDir.path}/BooksSource');
    if (!await pdfDir.exists()) {
      print('[LoadBooks] BooksSource dir does not exist, creating...');
      await pdfDir.create(recursive: true);
    } else {
      print('[LoadBooks] BooksSource dir already exists');
    }

    // Read AssetManifest and copy packaged assets into writable app documents.
    // Use a marker file so copying only occurs once (or when you want to force it).
    try {
      final marker = File('${appDir.path}${Platform.pathSeparator}.assets_copied');
      if (await marker.exists()) {
        print('[LoadBooks] Assets already copied (marker present) - skipping packaged copy');
      } else {
        print('[LoadBooks] Attempting to load AssetManifest.json for packaged assets');
        final manifestContent = await rootBundle.loadString('AssetManifest.json');
        print('[LoadBooks] AssetManifest.json loaded successfully');
        final Map<String, dynamic> manifest = jsonDecode(manifestContent);

        Future<void> _copyPrefix(String prefix, Directory targetDir, List<String> exts) async {
          final entries = manifest.keys.where((k) => k.startsWith(prefix) && exts.any((e) => k.toLowerCase().endsWith(e))).toList();
          print('[LoadBooks] Found ${entries.length} assets under $prefix');
          if (!await targetDir.exists()) await targetDir.create(recursive: true);
          for (var assetPath in entries) {
            try {
              final bytes = await rootBundle.load(assetPath);
              final fileName = assetPath.split('/').last;
              final out = File('${targetDir.path}${Platform.pathSeparator}$fileName');
              if (!await out.exists()) {
                print('[LoadBooks] Copying asset $assetPath -> ${out.path}');
                await out.writeAsBytes(bytes.buffer.asUint8List());
              } else {
                print('[LoadBooks] Asset ${out.path} already exists, skipping');
              }
            } catch (e) {
              print('[LoadBooks] Error copying $assetPath: $e');
            }
          }
        }

        // Copy PDFs into Documents/BooksSource
        await _copyPrefix('assets/BooksSource/', pdfDir, ['.pdf']);
        // Copy txt fallback books into Documents/TxtBooks
        final txtDir = Directory('${appDir.path}${Platform.pathSeparator}TxtBooks');
        await _copyPrefix('assets/txt_books/', txtDir, ['.txt']);
        // Copy table_of_contents into Documents/table_of_contents
        final tocDir = Directory('${appDir.path}${Platform.pathSeparator}table_of_contents');
        await _copyPrefix('assets/table_of_contents/', tocDir, ['.txt']);
        // Copy images into Documents/BooksSource so localImagePath can find covers
        await _copyPrefix('assets/images/', pdfDir, ['.png', '.jpg', '.jpeg']);

        // Write marker so we don't copy again on every startup
        try {
          await marker.writeAsString(DateTime.now().toIso8601String());
          print('[LoadBooks] Asset copy marker written: ${marker.path}');
        } catch (e) {
          print('[LoadBooks] Failed to write asset copy marker: $e');
        }
      }
    } catch (e) {
      print('[LoadBooks] CRITICAL ERROR reading AssetManifest.json or copying assets: $e');
      // Fallback: try to load the explicitly-declared assets directly
      // from the asset bundle (useful when AssetManifest.json is unavailable).
      try {
        print('[LoadBooks] Attempting manual copy of declared assets from bundle');
        final txtDir = Directory('${appDir.path}${Platform.pathSeparator}TxtBooks');
        final tocDir = Directory('${appDir.path}${Platform.pathSeparator}table_of_contents');
        if (!await txtDir.exists()) await txtDir.create(recursive: true);
        if (!await tocDir.exists()) await tocDir.create(recursive: true);

        final declaredPdfAssets = <String>[
          'assets/BooksSource/edliz 2020.pdf',
          'assets/BooksSource/Guidelines-for-HIV-Prevention-Testing-and-Treatment-of-HIV-in-Zimbabwe-August-2022-1.pdf',
          'assets/BooksSource/National TB and Leprosy Guidelines_FINAL 2023_Signed.pdf',
          'assets/BooksSource/Zimbabwe Malaria Treatment Guidelines 2015.pdf',
        ];

        final declaredImageAssets = <String>[
          'assets/images/edliz 2020.png',
          'assets/images/Guidelines-for-HIV-Prevention-Testing-and-Treatment-of-HIV-in-Zimbabwe-August-2022-1.png',
          'assets/images/National TB and Leprosy Guidelines_FINAL 2023_Signed.png',
          'assets/images/Zimbabwe Malaria Treatment Guidelines 2015.png',
        ];

        final declaredTxtAssets = <String>[
          'assets/txt_books/edliz 2020.txt',
          'assets/txt_books/Guidelines-for-HIV-Prevention-Testing-and-Treatment-of-HIV-in-Zimbabwe-August-2022-1.txt',
          'assets/txt_books/National TB and Leprosy Guidelines_FINAL 2023_Signed.txt',
          'assets/txt_books/Zimbabwe Malaria Treatment Guidelines 2015.txt',
          'assets/table_of_contents/edliz 2020.txt',
          'assets/table_of_contents/National TB and Leprosy Guidelines_FINAL 2023_Signed.txt',
          'assets/table_of_contents/Zimbabwe Malaria Treatment Guidelines 2015.txt',
        ];

        Future<void> _tryLoadBinary(String assetPath, Directory targetDir) async {
          try {
            final data = await rootBundle.load(assetPath);
            final fileName = assetPath.split('/').last;
            final out = File('${targetDir.path}${Platform.pathSeparator}$fileName');
            if (!await out.exists()) {
              await out.writeAsBytes(data.buffer.asUint8List());
              print('[LoadBooks] Manual copied asset $assetPath -> ${out.path}');
            } else {
              print('[LoadBooks] Manual asset already exists ${out.path}');
            }
          } catch (e) {
            print('[LoadBooks] Manual load failed for $assetPath: $e');
          }
        }

        Future<void> _tryLoadText(String assetPath, Directory targetDir) async {
          try {
            final content = await rootBundle.loadString(assetPath);
            final fileName = assetPath.split('/').last;
            final out = File('${targetDir.path}${Platform.pathSeparator}$fileName');
            if (!await out.exists()) {
              await out.writeAsString(content);
              print('[LoadBooks] Manual copied text asset $assetPath -> ${out.path}');
            } else {
              print('[LoadBooks] Manual text asset already exists ${out.path}');
            }
          } catch (e) {
            print('[LoadBooks] Manual text load failed for $assetPath: $e');
          }
        }

        for (var a in declaredPdfAssets) {
          await _tryLoadBinary(a, pdfDir);
        }
        for (var a in declaredImageAssets) {
          await _tryLoadBinary(a, pdfDir);
        }
        for (var a in declaredTxtAssets) {
          // txt_books should go to TxtBooks; table_of_contents entries go to tocDir
          if (a.startsWith('assets/txt_books/')) {
            await _tryLoadText(a, txtDir);
          } else {
            await _tryLoadText(a, tocDir);
          }
        }
      } catch (e2) {
        print('[LoadBooks] Manual asset fallback also failed: $e2');
      }
    }

    // If AssetManifest wasn't available or assets weren't packaged, try
    // copying files directly from the project workspace `assets/` folder
    // into the application's documents directories. This makes testing
    // easier when running from source or when assets weren't bundled.
    try {
      final projectAssetsRoot = Directory('${Directory.current.path}${Platform.pathSeparator}assets');
      if (await projectAssetsRoot.exists()) {
        print('[LoadBooks] Project assets folder found: ${projectAssetsRoot.path} - copying missing files to app documents');
        // Copy PDFs into Documents/BooksSource
        try {
          final projectPdfs = Directory('${projectAssetsRoot.path}${Platform.pathSeparator}BooksSource');
          if (await projectPdfs.exists()) {
            for (var src in projectPdfs.listSync().whereType<File>().where((f) => f.path.toLowerCase().endsWith('.pdf'))) {
              final dest = File('${pdfDir.path}${Platform.pathSeparator}${src.path.split(Platform.pathSeparator).last}');
              if (!await dest.exists()) {
                try {
                  await src.copy(dest.path);
                  print('[LoadBooks] Copied PDF from project assets: ${src.path} -> ${dest.path}');
                } catch (e) {
                  print('[LoadBooks] Failed to copy PDF ${src.path}: $e');
                }
              }
            }
          }
        } catch (e) {
          print('[LoadBooks] Error copying project PDFs: $e');
        }

        // Copy TXT fallback books into Documents/TxtBooks
        try {
          final projectTxt = Directory('${projectAssetsRoot.path}${Platform.pathSeparator}txt_books');
          final txtDir = Directory('${appDir.path}/TxtBooks');
          if (!await txtDir.exists()) await txtDir.create(recursive: true);
          if (await projectTxt.exists()) {
            for (var src in projectTxt.listSync().whereType<File>().where((f) => f.path.toLowerCase().endsWith('.txt'))) {
              final dest = File('${txtDir.path}${Platform.pathSeparator}${src.path.split(Platform.pathSeparator).last}');
              if (!await dest.exists()) {
                try {
                  await src.copy(dest.path);
                  print('[LoadBooks] Copied TXT from project assets: ${src.path} -> ${dest.path}');
                } catch (e) {
                  print('[LoadBooks] Failed to copy TXT ${src.path}: $e');
                }
              }
            }
          }
        } catch (e) {
          print('[LoadBooks] Error copying project TXT files: $e');
        }

        // Copy table_of_contents into Documents/table_of_contents
        try {
          final projectToc = Directory('${projectAssetsRoot.path}${Platform.pathSeparator}table_of_contents');
          final tocDir = Directory('${appDir.path}${Platform.pathSeparator}table_of_contents');
          if (!await tocDir.exists()) await tocDir.create(recursive: true);
          if (await projectToc.exists()) {
            for (var src in projectToc.listSync().whereType<File>().where((f) => f.path.toLowerCase().endsWith('.txt'))) {
              final dest = File('${tocDir.path}${Platform.pathSeparator}${src.path.split(Platform.pathSeparator).last}');
              if (!await dest.exists()) {
                try {
                  await src.copy(dest.path);
                  print('[LoadBooks] Copied TOC from project assets: ${src.path} -> ${dest.path}');
                } catch (e) {
                  print('[LoadBooks] Failed to copy TOC ${src.path}: $e');
                }
              }
            }
          }
        } catch (e) {
          print('[LoadBooks] Error copying project TOC files: $e');
        }

        // Copy images into Documents/BooksSource so localImagePath can find covers
        try {
          final projectImages = Directory('${projectAssetsRoot.path}${Platform.pathSeparator}images');
          if (await projectImages.exists()) {
            for (var src in projectImages.listSync().whereType<File>().where((f) => f.path.toLowerCase().endsWith('.png') || f.path.toLowerCase().endsWith('.jpg') || f.path.toLowerCase().endsWith('.jpeg'))) {
              final dest = File('${pdfDir.path}${Platform.pathSeparator}${src.path.split(Platform.pathSeparator).last}');
              if (!await dest.exists()) {
                try {
                  await src.copy(dest.path);
                  print('[LoadBooks] Copied image from project assets: ${src.path} -> ${dest.path}');
                } catch (e) {
                  print('[LoadBooks] Failed to copy image ${src.path}: $e');
                }
              }
            }
          }
        } catch (e) {
          print('[LoadBooks] Error copying project images: $e');
        }
      } else {
        print('[LoadBooks] Project assets folder not found at ${projectAssetsRoot.path}');
      }
    } catch (e) {
      print('[LoadBooks] Error while attempting to copy project assets: $e');
    }

    print('[LoadBooks] Listing PDFs from ${pdfDir.path}');
    var files = pdfDir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.toLowerCase().endsWith('.pdf'))
        .toList();
    print('[LoadBooks] Found ${files.length} PDF files in BooksSource (documents dir)');
    for (var f in files) {
      print('[LoadBooks] PDF (documents): ${f.path}');
    }

    // Fallback for local development and device testing:
    // 1) Check the project's `assets/BooksSource` (useful on desktop/debug runs)
    // 2) Check common external storage paths on Android devices (e.g. /sdcard/BooksSource)
    if (files.isEmpty) {
      // Helper to try a directory and append matching PDFs to `files`
      Future<void> _tryDir(Directory d, String tag) async {
        try {
          if (await d.exists()) {
            final found = d
                .listSync()
                .whereType<File>()
                .where((f) => f.path.toLowerCase().endsWith('.pdf'))
                .toList();
            if (found.isNotEmpty) {
              print('[LoadBooks] Found ${found.length} PDF files in $tag: ${d.path}');
              for (var f in found) print('[LoadBooks] PDF ($tag): ${f.path}');
              // If these are external/device files, copy them into the app's
              // Documents/BooksSource directory so they persist and are used
              // by the rest of the app. This will also normalize paths.
              try {
                final List<File> copied = [];
                for (var src in found) {
                  final name = src.path.split(Platform.pathSeparator).last;
                  final destPath = '${pdfDir.path}${Platform.pathSeparator}$name';
                  final dest = File(destPath);
                  if (!await dest.exists()) {
                    try {
                      await src.copy(dest.path);
                      print('[LoadBooks] Copied external file to documents: ${src.path} -> ${dest.path}');
                    } catch (e) {
                      print('[LoadBooks] Failed to copy external file ${src.path}: $e');
                    }
                  }
                  copied.add(dest);
                }
                files = copied;
              } catch (e) {
                print('[LoadBooks] Error copying external files into documents: $e');
                files = found;
              }
            } else {
              print('[LoadBooks] No PDFs in $tag: ${d.path}');
            }
          } else {
            print('[LoadBooks] $tag dir does not exist: ${d.path}');
          }
        } catch (e) {
          print('[LoadBooks] Error while checking $tag: $e');
        }
      }

      // 1) Project assets (desktop/debug)
      final projectAssetsDir = Directory('${Directory.current.path}${Platform.pathSeparator}assets${Platform.pathSeparator}BooksSource');
      await _tryDir(projectAssetsDir, 'project assets');

      // 2) Android external storage candidates
      final candidates = <Directory>[
        Directory('/sdcard/BooksSource'),
        Directory('/storage/emulated/0/BooksSource'),
        Directory('/sdcard/Download/BooksSource'),
        Directory('/storage/emulated/0/Download/BooksSource')
      ];
      for (var d in candidates) {
        if (files.isEmpty) await _tryDir(d, 'external');
      }
    }
    setState(() {
      _allBooks = files;
      _filteredBooks = List.from(_allBooks);
    });
    print('[LoadBooks] _loadBooks complete. _allBooks.length = ${_allBooks.length}');
  }

  // Debug helper: show asset manifest entries and documents BooksSource files
  Future<void> _showAssetDiagnostics() async {
    final buffer = StringBuffer();
    List<String> assetEntries = [];
    try {
      final manifestContent = await rootBundle.loadString('AssetManifest.json');
      final Map<String, dynamic> manifest = jsonDecode(manifestContent);
      assetEntries = manifest.keys
          .where((k) => k.startsWith('assets/BooksSource/') || k.startsWith('assets/txt_books/') || k.startsWith('assets/table_of_contents/'))
          .toList();
      buffer.writeln('AssetManifest entries under assets/BooksSource, txt_books, table_of_contents: ${assetEntries.length}');
      for (var e in assetEntries) buffer.writeln(e);
    } catch (e) {
      buffer.writeln('Failed to read AssetManifest.json: $e');
    }

    try {
      final Directory appDir = await getApplicationDocumentsDirectory();
      final pdfDir = Directory('${appDir.path}/BooksSource');
      if (await pdfDir.exists()) {
        final files = pdfDir.listSync().whereType<File>().toList();
        buffer.writeln('\nFiles in Documents/BooksSource (${files.length}):');
        for (var f in files) buffer.writeln(f.path.split(Platform.pathSeparator).last);
      } else {
        buffer.writeln('\nDocuments/BooksSource does not exist');
      }
      final txtDir = Directory('${appDir.path}/TxtBooks');
      if (await txtDir.exists()) {
        final files = txtDir.listSync().whereType<File>().toList();
        buffer.writeln('\nFiles in Documents/TxtBooks (${files.length}):');
        for (var f in files) buffer.writeln(f.path.split(Platform.pathSeparator).last);
      }
    } catch (e) {
      buffer.writeln('\nFailed to list application documents: $e');
    }

    if (!mounted) return;
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Asset diagnostics'),
        content: SingleChildScrollView(child: Text(buffer.toString())),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Close'))
        ],
      ),
    );
  }

  /// Delete the asset-copy marker and re-run the packaged-asset copy routine.
  /// This forces copying all files from AssetManifest into the app documents.
  Future<void> _forceImportAssets() async {
    try {
      final Directory appDir = await getApplicationDocumentsDirectory();
      final marker = File('${appDir.path}${Platform.pathSeparator}.assets_copied');
      if (await marker.exists()) {
        await marker.delete();
        print('[LoadBooks] Removed asset copy marker: ${marker.path}');
      } else {
        print('[LoadBooks] No asset copy marker present; will copy assets');
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Importing packaged assets...')));
      await _loadBooks();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Asset import finished')));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Asset import failed: $e')));
      print('[LoadBooks] Error during forced import: $e');
    }
  }

  Future<void> _openBook(File book) async {
    // Enqueue the open request and process sequentially to avoid concurrent
    // opens which can crash the app when multiple PDF engines are touched.
    _openQueue.add(book);
    if (_processingOpenQueue) return; // already processing
    _processingOpenQueue = true;

    while (_openQueue.isNotEmpty) {
      final next = _openQueue.removeAt(0);
      // Prevent re-entrancy guard per-file
      if (_isOpening) continue;
      _isOpening = true;

      // Show a dialog with a gentle scale animation and a circular loader to give
      // a smooth "pushed to open" feel. We keep the animation short and then
      // reveal the PDF viewer.
      // ignore: use_build_context_synchronously
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) {
          return Center(
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: 0.88, end: 1.0),
              duration: const Duration(milliseconds: 420),
              curve: Curves.easeOutCubic,
              builder: (context, val, child) {
                return Transform.scale(
                  scale: val,
                  child: Container(
                    width: 220,
                    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [Color(0xFF1976D2), Color(0xFF1E88E5)],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      borderRadius: BorderRadius.circular(12),
                      boxShadow: [
                        BoxShadow(
                            color: Colors.black26, blurRadius: 12, offset: const Offset(0, 6)),
                      ],
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const SizedBox(height: 6),
                        SizedBox(
                          width: 48,
                          height: 48,
                          child: CircularProgressIndicator(
                            strokeWidth: 3.5,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(height: 12),
                        const Text(
                          'Opening book…',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: Colors.white,
                            decoration: TextDecoration.none,
                          ),
                        ),
                        const SizedBox(height: 6),
                        const Text(
                          'Loading content — this may take a moment',
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 12, color: Colors.white70, decoration: TextDecoration.none),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          );
        },
      );

      try {
        // Small cooperative delay so animation is visible and user perceives smoothness
        await Future.delayed(const Duration(milliseconds: 480));

        // Ensure controller exists and then set the active book in the UI
        if (mounted) {
          setState(() {
            _isPdfLoading = true;
            _activeBook = next;
            _pdfBookmarked = _bookmarks.contains(next.path);
            _pdfController = PdfViewerController();
          });
        }

        // Allow a tiny extra moment to let the UI settle before removing the dialog
        await Future.delayed(const Duration(milliseconds: 120));
        // Attempt to read the PDF outline (TOC) in a non-blocking way and cache it
        try {
          Future.microtask(() async {
            try {
              final doc = await pdfx.PdfDocument.openFile(next.path);
              final dynamic outlines =
              await (doc as dynamic).getOutline?.call();
              // store outlines in a lightweight cache on the widget state
              if (mounted) {
                setState(() {
                  // Represent outlines as a simple list of maps for compatibility
                  // with the existing custom TOC UI which expects title/page pairs.
                  if (outlines != null && outlines.isNotEmpty) {
                    final List<Map<String, dynamic>> custom = [];
                    void walk(dynamic ols) {
                      try {
                        for (var o in (ols as Iterable)) {
                          try {
                            final title =
                                (o?.title?.toString()) ?? 'Untitled';
                            final pageIdx = (o?.pageIndex is int)
                                ? (o.pageIndex as int)
                                : (o?.page?.toInt() ?? 0);
                            custom.add({'title': title, 'page': pageIdx + 1});
                            if (o?.children != null) walk(o.children);
                          } catch (_) {}
                        }
                      } catch (_) {}
                    }

                    if (outlines != null) walk(outlines);
                    // save as custom toc file so UI picks it up
                    _saveCustomToc(next, custom);
                  }
                });
              }
              try {
                final d = doc as dynamic;
                if (d.dispose != null) {
                  await d.dispose();
                } else if (d.close != null) {
                  await d.close();
                }
              } catch (_) {}
            } catch (e) {
              // Outline extraction failed; ignore and continue.
              print('[TOC] outline extract failed: $e');
            }
          });
        } catch (_) {}
      } finally {
        // Do not close the dialog here — keep it visible until the PDF viewer
        // reports the document is loaded (see onDocumentLoaded). This gives a
        // smoother experience where the loader remains until content is ready.
        _isOpening = false;
      }

      // Wait for the PDF viewer to finish loading (or timeout) before closing the dialog.
      // This polls the `_isPdfLoading` flag which is cleared by the viewer's
      // `onDocumentLoaded` / `onDocumentLoadFailed` callbacks.
      try {
        const int maxWaitMs = 20000; // 20s max
        int waited = 0;
        while ((_isPdfLoading) && waited < maxWaitMs) {
          await Future.delayed(const Duration(milliseconds: 200));
          waited += 200;
        }
      } catch (_) {}

      // Close the dialog if it's still open
      try {
        // ignore: use_build_context_synchronously
        Navigator.of(context).pop();
      } catch (_) {}

      // Kick off indexing silently in background (no dialog shown)
      // Silently index the book in the background so it's ready for questions.
      // This runs without blocking the UI and without showing dialogs.
      // The indexing operation is safely isolated: if it fails, the book can
      // still be viewed/opened, but questions may be unavailable or use fallback paths.
      Future.microtask(() async {
        try {
          if (_activeBook != null) {
            print('[OpenBook] Starting silent background indexing for ${_activeBook!.path}');
            await _ensureBookIndexed(_activeBook!);
            print('[OpenBook] Silent background indexing complete for ${_activeBook!.path}');
          }
        } catch (e, st) {
          print('[OpenBook] Silent background indexing error (non-critical, book can still be viewed): $e\n$st');
        }
      });
    }

    _processingOpenQueue = false;
  }

  // Delete a book PDF and its companion files from app documents
  Future<void> _deleteBookFiles(File book) async {
    final messenger = ScaffoldMessenger.of(context);
    final dir = await getApplicationDocumentsDirectory();
    final base = _stripPdfExt(book.path);

    // Candidate files to delete
    final pdfFile = book;
    final pngFile = File('${dir.path}/BooksSource/$base.png');
    final tocFile = File('${dir.path}/table_of_contents/$base.txt');
    final txtFile = File('${dir.path}/TxtBooks/$base.txt');

    final deleted = <String>[];
    final failed = <String>[];

    // If the book is currently open in the viewer, close it first (some platforms lock the file)
    try {
      if (_activeBook != null && _activeBook!.path == pdfFile.path) {
        _closeBook();
      }
    } catch (_) {}

    Future<void> tryDelete(File f, String label) async {
      try {
        if (await f.exists()) {
          await f.delete();
          deleted.add(label);
        }
      } catch (e) {
        failed.add('$label (${f.path}): $e');
      }
    }

    await tryDelete(pdfFile, 'pdf');
    await tryDelete(pngFile, 'image');
    await tryDelete(tocFile, 'toc');
    await tryDelete(txtFile, 'txt');

    // Refresh library regardless
    try {
      await _loadBooks();
    } catch (_) {}

    if (failed.isEmpty) {
      messenger.showSnackBar(
          SnackBar(content: Text('Deleted: ${deleted.join(', ')}')));
    } else {
      // Give a helpful message for Android emulator permission/path issues
      messenger.showSnackBar(SnackBar(
          content:
          Text('Deleted: ${deleted.join(', ')}. Failed: ${failed.join(' ; ')}')));
    }
  }

  // Ensure a given book has been indexed into the vector DB. Optionally pass an onProgress callback.
  // This function uses a multi-stage fallback strategy to guarantee every book gets indexed:
  // 1. Check if already indexed (skip if so)
  // 2. Try TXT fallback (Documents/TxtBooks or bundled assets)
  // 3. Try PDF text extraction (whole doc, per-page, direct, OCR)
  // 4. Fall back to stored book text from VectorDB
  // 5. If all else fails, index a permissive synthetic chunk so book is marked as "indexed"
  Future<void> _ensureBookIndexed(File book,
      {void Function(int done, int total)? onProgress}) async {
    final bookId = book.path.split(Platform.pathSeparator).last;
    print('[Index] _ensureBookIndexed called for $bookId');
    
    final existing = await VectorDB.chunksCountForBook(bookId);
    if (existing > 0) {
      print('[Index] Book already indexed ($existing chunks) — skipping');
      return;
    }

    String fullText = '';

    // === Stage 1: Try TXT fallback (fastest path) ===
    print('[Index] Stage 1: Attempting TXT fallback load');
    try {
      fullText = await _loadTxtFallbackForBook(bookId) ?? '';
      if (fullText.trim().isNotEmpty) {
        print('[Index] Stage 1 SUCCESS: Loaded TXT fallback (${fullText.length} chars)');
      } else {
        print('[Index] Stage 1: No TXT fallback found');
      }
    } catch (e) {
      print('[Index] Stage 1: TXT fallback load failed: $e');
    }

    // === Stage 2: If TXT failed, try PDF text extraction ===
    if (fullText.trim().isEmpty) {
      print('[Index] Stage 2: Attempting PDF text extraction');
      try {
        // Use extended timeout for extraction (handle difficult PDFs)
        final pages = await _extractAllPagesText(book)
            .timeout(const Duration(seconds: 45));
        
        final nonEmptyCount = pages.where((p) => p.trim().isNotEmpty).length;
        if (nonEmptyCount > 0) {
          fullText = pages.join('\n\n');
          print('[Index] Stage 2 SUCCESS: Extracted $nonEmptyCount non-empty pages (${fullText.length} chars)');
        } else {
          print('[Index] Stage 2: Extraction returned ${pages.length} pages but all empty');
        }
      } on TimeoutException catch (e) {
        print('[Index] Stage 2: Extraction timed out after 45s: $e');
      } catch (e) {
        print('[Index] Stage 2: Extraction failed: $e');
      }
    }

    // === Stage 3: Try stored book text from VectorDB ===
    if (fullText.trim().isEmpty) {
      print('[Index] Stage 3: Attempting VectorDB.getBookText() fallback');
      try {
        final stored = await VectorDB.getBookText(bookId);
        if (stored != null && stored.trim().isNotEmpty) {
          fullText = stored;
          print('[Index] Stage 3 SUCCESS: Loaded stored book text (${fullText.length} chars)');
        } else {
          print('[Index] Stage 3: No stored book text found');
        }
      } catch (e) {
        print('[Index] Stage 3: getBookText fallback failed: $e');
      }
    }

    // === Stage 4: Last resort — create a permissive synthetic chunk ===
    // This ensures even difficult PDFs are marked as "indexed" and available for questions
    if (fullText.trim().isEmpty) {
      print('[Index] Stage 4: Creating permissive synthetic chunk (last resort)');
      fullText = '''
Book: $bookId

This is a fallback entry for a book that could not be fully extracted.
Users can still ask questions about this book; the system will attempt to find
relevant information from the document or provide general medical knowledge.

If you encounter issues with this book, please report the filename and error details.
      ''';
    }

    // === Final: Index the text ===
    if (fullText.trim().isEmpty) {
      print('[Index] ERROR: No text available after all stages — cannot index $bookId');
      return;
    }

    print('[Index] Starting VectorDB.indexTextForBook for $bookId (${fullText.length} chars)');
    try {
      final inserted = await VectorDB.indexTextForBook(bookId, fullText,
          embedder: null, // no embeddings needed for basic indexing
          chunkSize: 1000 // same chunk size as in integration test
          );
      print('[Index] SUCCESS: Indexed $bookId with $inserted chunks');
      
      // Final progress update
      if (onProgress != null) {
        onProgress(inserted, inserted);
      }
      if (mounted) {
        setState(() {
          _indexDone = inserted;
          _indexTotal = inserted;
        });
      }
    } catch (e, st) {
      print('[Index] ERROR during final indexing: $e\n$st');
      rethrow;
    }
  }

  Future<void> _startIndexActiveBook() async {
    if (_activeBook == null) return;
    if (_isIndexing) return;
    _isIndexing = true;
    _indexDone = 0;
    _indexTotal = 0;
    _indexingCancelled = false;

    // show a dialog with progress and a cancel button
    // ignore: use_build_context_synchronously
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return StatefulBuilder(builder: (ctx, setStateDialog) {
          // keep updating from outer state via setState calls
          return AlertDialog(
            title: const Text('Indexing book'),
            content: SizedBox(
              width: 400,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_indexTotal > 0)
                    LinearProgressIndicator(value: _indexDone / _indexTotal)
                  else
                    const LinearProgressIndicator(),
                  const SizedBox(height: 12),
                  Text(
                      'Indexed $_indexDone of ${_indexTotal == 0 ? '?' : _indexTotal} chunks'),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () {
                  _indexingCancelled = true;
                  Navigator.pop(ctx);
                },
                child: const Text('Cancel'),
              ),
            ],
          );
        });
      },
    );

    try {
      await _ensureBookIndexed(_activeBook!,
          onProgress: (done, total) {
            setState(() {
              _indexDone = done;
              _indexTotal = total;
            });
          });
    } finally {
      _isIndexing = false;
      _indexingCancelled = false;
      // close dialog if still open
      try {
        // ignore: use_build_context_synchronously
        Navigator.of(context).pop();
      } catch (_) {}
    }
  }

  // Train the currently active book with OpenAI to generate Q/A pairs for offline use
  Future<void> _trainActiveBook() async {
    if (_activeBook == null) return;
    final messenger = ScaffoldMessenger.of(context);
    final key = await _getOpenAiKey();
    if (key == null || key.isEmpty) {
      messenger.showSnackBar(const SnackBar(
          content:
          Text('OpenAI API key not set. Please save it in Settings.')));
      return;
    }

    // Ensure book is indexed (chunks present). If not, ask the user to index first.
    final bookId = _activeBook!.path.split(Platform.pathSeparator).last;
    final existing = await VectorDB.chunksCountForBook(bookId);
    if (existing == 0) {
      messenger.showSnackBar(const SnackBar(
          content: Text(
              'Book is not indexed. Index the book first (Index book)')));
      return;
    }

    // Load chunks for the book
    final chunks = await VectorDB.chunksForBook(bookId);

    // ignore: use_build_context_synchronously
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );

    try {
      final backend = await BackendConfig.getInstance();
      final embSvc = EmbeddingService(backend);
      final rag = RagService(embSvc, backend);
      await rag.trainBookWithOpenAI(bookId, chunks);
      messenger.showSnackBar(const SnackBar(
          content:
          Text('Training complete — Q/A pairs saved for offline use')));
    } catch (e) {
      messenger.showSnackBar(
          SnackBar(content: Text('Training failed: ${e.toString()}')));
    } finally {
      try {
        // ignore: use_build_context_synchronously
        Navigator.of(context).pop();
      } catch (_) {}
    }
  }

  // Per-book cache file for extracted pages
  Future<File> _pagesCacheFileForBook(File book) async {
    final dir = await getApplicationDocumentsDirectory();
    final safeName = book.path
        .split(Platform.pathSeparator)
        .last
        .replaceAll(RegExp(r'[^a-zA-Z0-9_.-]'), '_');
    return File('${dir.path}/$safeName.pages.json');
  }

  // Search a book's pages for a query and return top-K matching excerpts.
  // If forceReExtract is true, we bypass any cached page text and re-run PDF extraction.
  Future<List<Map<String, dynamic>>> _searchBookForQuery(
      File book, String query,
      {int topK = 5, bool forceReExtract = false}) async {
    List<String> pages = [];

    try {
      final cacheFile = await _pagesCacheFileForBook(book);
      if (!forceReExtract && await cacheFile.exists()) {
        try {
          final raw = await cacheFile.readAsString();
          final decoded = jsonDecode(raw) as List<dynamic>;
          pages = decoded.map((e) => e?.toString() ?? '').toList();
        } catch (_) {
          pages = [];
        }
      }

      if (pages.isEmpty) {
        try {
          // PDF extraction can be slow and sometimes hang; enforce a timeout to avoid app freeze/crash.
          pages = await _extractAllPagesText(book)
              .timeout(const Duration(seconds: 12));
        } on TimeoutException {
          // Extraction timed out; return empty so caller can offer force re-extract.
          pages = [];
        }

        // If extraction failed / returned empty pages, try fallback to sibling TXT or toc files
        final hasNonEmpty = pages.any((p) => p.isNotEmpty);
        if (!hasNonEmpty) {
          try {
            final pdfDir = book.parent;
            final base = _stripPdfExt(book.path);
            final candidate1 = File('${pdfDir.path}/$base.txt');
            final candidate2 = File('${pdfDir.path}/toc.txt');
            final candidate3 = File('${pdfDir.path}/toc.json');
            if (await candidate1.exists()) {
              final t = await candidate1.readAsString();
              pages = [t];
            } else if (await candidate2.exists()) {
              final t = await candidate2.readAsString();
              pages = [t];
            } else if (await candidate3.exists()) {
              final t = await candidate3.readAsString();
              // Try to parse json: if it's an array of objects with 'title' or so, use textual join
              try {
                final parsed = jsonDecode(t);
                if (parsed is List) {
                  pages = [parsed.map((e) => e.toString()).join('\n')];
                } else {
                  pages = [t];
                }
              } catch (_) {
                pages = [t];
              }
            }
          } catch (_) {}
        }

        // cache whatever pages we have for faster future queries
        try {
          final cacheFile2 = await _pagesCacheFileForBook(book);
          await cacheFile2.writeAsString(jsonEncode(pages));
        } catch (_) {}
      }
    } catch (_) {
      pages = [];
    }

    final q = query.toLowerCase();
    // Basic normalization and token list
    final baseTokens = q
        .replaceAll(RegExp(r"[^a-z0-9 ]"), ' ')
        .split(RegExp(r"\\s+"))
        .where((s) => s.length > 2)
        .toList();
    // Small synonym map to catch different phrasings for common health queries
    final synonyms = <String, List<String>>{
      'treat': ['treat', 'treatment', 'manage', 'management', 'therapy'],
      'cause': ['cause', 'causes', 'caused', 'etiology'],
      'symptom': ['symptom', 'symptoms', 'signs'],
      'prevent': ['prevent', 'prevention', 'prophylaxis'],
      'diagnos': ['diagnos', 'diagnosis', 'test', 'testing'],
    };
    final tokens = <String>[]..addAll(baseTokens);
    for (var t in baseTokens) {
      for (var k in synonyms.keys) {
        if (t.contains(k)) tokens.addAll(synonyms[k]!);
      }
    }
    final hits = <Map<String, dynamic>>[];
    for (var i = 0; i < pages.length; i++) {
      final txt = pages[i];
      if (txt.isEmpty) continue;
      final low = txt.toLowerCase();
      int score = 0;
      for (var t in tokens) {
        if (low.contains(t)) score += 1;
      }
      if (score > 0) {
        // find first matching token index
        int idx = -1;
        for (var t in tokens) {
          idx = low.indexOf(t);
          if (idx >= 0) break;
        }
        if (idx < 0) idx = 0;
        final start = (idx - 120).clamp(0, txt.length);
        final end = (idx + 120).clamp(0, txt.length);
        final excerpt =
        txt.substring(start, end).replaceAll('\n', ' ').trim();
        hits.add({'page': i + 1, 'text': excerpt, 'score': score});
      }
    }
    hits.sort((a, b) => (b['score'] as int).compareTo(a['score'] as int));
    return hits.take(topK).toList();
  }

  void _closeBook() {
    setState(() {
      _activeBook = null;
    });
  }

  // Helper to build nice tool buttons for the top bar
  Widget _buildToolButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback onPressed,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Tooltip(
        message: tooltip,
        child: Container(
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.15),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: Colors.white.withOpacity(0.3),
              width: 1,
            ),
          ),
          child: IconButton(
            icon: Icon(icon, color: Colors.white, size: 20),
            onPressed: onPressed,
            padding: const EdgeInsets.all(6),
            splashRadius: 20,
          ),
        ),
      ),
    );
  }

  void _toggleBookmark(File book) {
    setState(() {
      final id = book.path;
      if (_bookmarks.contains(id)) {
        _bookmarks.remove(id);
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Removed bookmark')));
      } else {
        _bookmarks.add(id);
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Bookmarked')));
      }
    });
  }

  void _toggleBookmarkForActive() {
    if (_activeBook == null) return;
    final id = _activeBook!.path;
    setState(() {
      if (_bookmarks.contains(id)) {
        _bookmarks.remove(id);
        _pdfBookmarked = false;
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Removed bookmark')));
      } else {
        _bookmarks.add(id);
        _pdfBookmarked = true;
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Bookmarked')));
      }
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    try {
      _autoSyncTimer?.cancel();
    } catch (_) {}
    super.dispose();
  }

  // If user opens in-place viewer (inside main scaffold) we use this to show TOC.
  // Persistent custom TOC storage file per book
  Future<File> _tocFileForBook(File book) async {
    final dir = await getApplicationDocumentsDirectory();
    final safeName = book.path
        .split(Platform.pathSeparator)
        .last
        .replaceAll(RegExp(r'[^a-zA-Z0-9_.-]'), '_');
    return File('${dir.path}/$safeName.toc.json');
  }

  Future<List<Map<String, dynamic>>> _loadCustomToc(File book) async {
    try {
      final bookName = book.path.split(Platform.pathSeparator).last;
      final base = _stripPdfExt(bookName);

      // 1) Prefer user-provided TOC in app documents folder: Documents/table_of_contents/<base>.txt
      final dir = await getApplicationDocumentsDirectory();
      final tocDir = Directory('${dir.path}/table_of_contents');
      final userTocFile = File('${tocDir.path}/$base.txt');
      if (await userTocFile.exists()) {
        final raw = await userTocFile.readAsString();
        final parsed = _parseTocText(raw);
        if (parsed.isNotEmpty) return parsed;
      }

      // 2) Fallback to bundled asset in assets/table_of_contents/<base>.txt
      try {
        final assetPath = 'assets/table_of_contents/$base.txt';
        final raw = await rootBundle.loadString(assetPath);
        final parsed = _parseTocText(raw);
        if (parsed.isNotEmpty) return parsed;
      } catch (_) {}

      // 3) Fallback to existing per-book saved JSON toc
      final f = await _tocFileForBook(book);
      if (!await f.exists()) return [];
      final raw = await f.readAsString();
      final data = jsonDecode(raw) as List<dynamic>;
      return data
          .map((e) => {'title': e['title'] as String, 'page': e['page'] as int})
          .toList();
    } catch (_) {
      return [];
    }
  }

  // Parse a simple text TOC where each meaningful line contains a title and a page number.
  // Examples:
  // Introduction................1
  // Chapter 1: Basics 5
  // Table of Contents
  List<Map<String, dynamic>> _parseTocText(String raw) {
    final lines = raw
        .split(RegExp(r'\r?\n'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    final results = <Map<String, dynamic>>[];
    final pageRegex = RegExp(r'(\d{1,4})\s*$');
    for (var line in lines) {
      // Skip lines that are just 'Table of Contents' headers
      if (line.toLowerCase().contains('table of contents')) continue;
      final m = pageRegex.firstMatch(line);
      if (m != null) {
        final page = int.tryParse(m.group(1) ?? '') ?? 0;
        final title = line
            .substring(0, m.start)
            .replaceAll(RegExp(r'[\.\s]+$'), '')
            .trim();
        if (title.isNotEmpty && page > 0) {
          results.add({'title': title, 'page': page});
        }
      }
    }
    return results;
  }

  Future<List<String>> _extractAllPagesText(File file) async {
    print('[Extract] Starting extraction for ${file.path}');
    try {
      final bytes = await file.readAsBytes();
      print('[Extract] Loaded ${bytes.length} bytes');
      final doc = PdfDocument(inputBytes: bytes);
      final pageCount = doc.pages.count;
      print('[Extract] PDF has $pageCount pages');
      final List<String> pages = List.filled(pageCount, '');

      // Helper to occasionally yield to the event loop so UI stays responsive
      Future<void> _yieldIfNeeded(int i) async {
        if (i % 6 == 0) await Future.delayed(const Duration(milliseconds: 12));
      }

      // Strategy 1: try whole-document extractor and split by form-feed
      print('[Extract] Strategy 1: Whole-document text extraction');
      try {
        final whole = (PdfTextExtractor(doc) as dynamic).extractText();
        if (whole != null && whole.isNotEmpty) {
          final parts = whole.split('\f');
          if (parts.length == pageCount) {
            for (var i = 0; i < pageCount; i++) {
              pages[i] = parts[i].trim();
            }
            doc.dispose();
            final nonEmpty = pages.where((p) => p.isNotEmpty).length;
            print('[Extract] Strategy 1 SUCCESS: $nonEmpty non-empty pages');
            return pages;
          }
        }
        print('[Extract] Strategy 1: Whole extraction did not yield page-aligned result');
      } catch (e) {
        print('[Extract] Strategy 1 failed: $e');
      }

      // Strategy 2: per-page extraction via extractor with page ranges
      // Different pdf_text extractor versions use different parameter names.
      print('[Extract] Strategy 2: Per-page text extraction (try multiple signatures)');
      try {
        for (var i = 0; i < pageCount; i++) {
          try {
            String pageTxt = '';
            final extractor = (PdfTextExtractor(doc) as dynamic);
            // Try common signatures in order until one works
            try {
              final txt = extractor.extractText(startPage: i + 1, endPage: i + 1);
              pageTxt = (txt ?? '').toString();
            } catch (_) {
              try {
                final txt = extractor.extractText(startPageIndex: i + 1, endPageIndex: i + 1);
                pageTxt = (txt ?? '').toString();
              } catch (_) {
                try {
                  final txt = extractor.extractText(start: i + 1, end: i + 1);
                  pageTxt = (txt ?? '').toString();
                } catch (e) {
                  // Last-resort: attempt to call without named args and hope for positional parameters
                  try {
                    final txt = Function.apply((extractor as dynamic).extractText, [i + 1, i + 1]);
                    pageTxt = (txt ?? '').toString();
                  } catch (e2) {
                    throw e2;
                  }
                }
              }
            }

            pages[i] = pageTxt.trim();
          } catch (e) {
            print('[Extract]   Page ${i + 1}: extraction failed ($e)');
            pages[i] = '';
          }
          await _yieldIfNeeded(i);
        }
        final nonEmpty = pages.where((p) => p.isNotEmpty).length;
        if (nonEmpty > 0) {
          doc.dispose();
          print('[Extract] Strategy 2 SUCCESS: $nonEmpty non-empty pages');
          return pages;
        }
        print('[Extract] Strategy 2: No non-empty pages extracted');
      } catch (e) {
        print('[Extract] Strategy 2 threw: $e');
      }

      // Strategy 3: direct page object text (try property access if method missing)
      print('[Extract] Strategy 3: Direct page text access (getText or text property)');
      try {
        for (var i = 0; i < pageCount; i++) {
          try {
            final page = (doc.pages as dynamic)[i];
            String pageTxt = '';
            try {
              // Try getText() if available
              final dyn = page as dynamic;
              if ((dyn as dynamic).getText is Function) {
                final extracted = dyn.getText();
                if (extracted != null) {
                  try {
                    pageTxt = (extracted.text as String).trim();
                  } catch (_) {
                    pageTxt = extracted.toString().trim();
                  }
                }
              } else if ((dyn as dynamic).text != null) {
                // Some implementations expose a `text` getter/property
                try {
                  pageTxt = (dyn.text as String).trim();
                } catch (_) {
                  pageTxt = dyn.text.toString().trim();
                }
              } else {
                throw 'No getText/text available on page object';
              }
            } catch (e) {
              print('[Extract]   Page ${i + 1}: direct text access failed ($e)');
              pageTxt = '';
            }

            pages[i] = pageTxt;
          } catch (e) {
            print('[Extract]   Page ${i + 1}: page read failed ($e)');
            pages[i] = '';
          }
          await _yieldIfNeeded(i);
        }
        final nonEmpty = pages.where((p) => p.isNotEmpty).length;
        if (nonEmpty > 0) {
          doc.dispose();
          print('[Extract] Strategy 3 SUCCESS: $nonEmpty non-empty pages');
          return pages;
        }
        print('[Extract] Strategy 3: No non-empty pages from direct access');
      } catch (e) {
        print('[Extract] Strategy 3 threw: $e');
      }

      // OCR fallback: rasterize pages in a background isolate (OcrWorker)
      print('[Extract][OCR] Strategy 4: OCR via rasterization');
      try {
        final tempDir = await getTemporaryDirectory();
        // Request rasterization for all pages (1-based page numbers)
        final pageNums = List<int>.generate(pageCount, (i) => i + 1);
        Map<int, Uint8List> images = {};
        try {
            print('[Extract][OCR] Batch rasterization (width=1400, timeout=60s)');
            images = await OcrWorker.rasterizePdfPages(file.path, pageNums,
              targetWidth: 1400, timeout: const Duration(seconds: 60));
            print('[Extract][OCR] Batch rasterization returned ${images.length} page images');
        } catch (e) {
          print('[Extract][OCR] Batch rasterization failed: $e');
        }

        // If batch rasterization returned no images (some PDFs may fail in batch mode),
        // attempt per-page rasterization with a smaller target width and shorter timeout.
        if (images.isEmpty) {
          print('[Extract][OCR] Attempting per-page rasterization (width=900, timeout=30s per page)');
          for (var pnum in pageNums) {
            try {
              try {
                final pageImgs = await OcrWorker.rasterizePdfPages(file.path, [pnum], targetWidth: 900, timeout: const Duration(seconds: 30));
                if (pageImgs.containsKey(pnum) && pageImgs[pnum] != null && pageImgs[pnum]!.isNotEmpty) {
                  images[pnum] = pageImgs[pnum]!;
                  print('[Extract][OCR]   Page $pnum: rasterized successfully');
                }
              } catch (e) {
                print('[Extract][OCR]   Page $pnum: per-page rasterize failed ($e)');
              }
            } catch (_) {}
            // yield occasionally
            if (pnum % 4 == 0) await Future.delayed(const Duration(milliseconds: 10));
          }
          print('[Extract][OCR] Per-page rasterization yielded ${images.length} page images');
        }

        final textRecognizer =
        TextRecognizer(script: TextRecognitionScript.latin);
        int ocrSuccessCount = 0;
        for (var i = 0; i < pageCount; i++) {
          try {
            final pnum = i + 1;
            final png = images[pnum];
            if (png != null && png.isNotEmpty) {
              final tmpFile = File('${tempDir.path}/ocr_page_${pnum}.png');
              await tmpFile.writeAsBytes(png);
              try {
                final inputImage = InputImage.fromFilePath(tmpFile.path);
                final recognized =
                await textRecognizer.processImage(inputImage);
                pages[i] = (recognized.text).trim();
                final len = pages[i].length;
                if (len > 0) {
                  ocrSuccessCount++;
                  print('[Extract][OCR]   Page $pnum: OCR extracted $len chars');
                } else {
                  print('[Extract][OCR]   Page $pnum: OCR succeeded but returned empty text');
                }
              } catch (e) {
                print('[Extract][OCR]   Page $pnum: OCR processing failed ($e)');
              }
              try {
                await tmpFile.delete();
              } catch (_) {}
            }
          } catch (e) {
            print('[Extract][OCR]   Page ${i + 1}: process error ($e)');
          }
          await _yieldIfNeeded(i);
        }

        try {
          await textRecognizer.close();
        } catch (_) {}

        final nonEmpty = pages.where((p) => p.isNotEmpty).length;
        if (nonEmpty > 0) {
          doc.dispose();
          print('[Extract][OCR] Strategy 4 SUCCESS: $nonEmpty pages with OCR text ($ocrSuccessCount had text)');
          return pages;
        }
        print('[Extract][OCR] Strategy 4: OCR yielded no non-empty pages');
      } catch (e, st) {
        print('[Extract][OCR] Strategy 4 failed entirely: $e\n$st');
      }

      // If everything failed, return empty strings per page
      print('[Extract] All strategies exhausted — returning ${pageCount} empty pages');
      for (var i = 0; i < pageCount; i++) pages[i] = '';
      doc.dispose();
      return pages;
    } catch (e, st) {
      print('[Extract][ERROR] Extraction failed for ${file.path}: $e\n$st');
      return [];
    }
  }

  Future<String?> _getOpenAiKey() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = prefs.getString('OPENAI_API_KEY');
      if (key != null && key.trim().isNotEmpty) return key.trim();
    } catch (_) {}
    // dart-define fallback
    const envKey =
    String.fromEnvironment('OPENAI_API_KEY', defaultValue: '');
    if (envKey.isNotEmpty) return envKey;
    return null;
  }

  // Load a text fallback for a book name (filename) from Documents/TxtBooks or bundled assets/txt_books
  Future<String?> _loadTxtFallbackForBook(String bookFileName) async {
    try {
      final base = _stripPdfExt(bookFileName);
      final dir = await getApplicationDocumentsDirectory();

      // 1) Prefer user TXT in Documents/TxtBooks
      final txtDir = Directory('${dir.path}/TxtBooks');
      try {
        final userFile = File('${txtDir.path}/$base.txt');
        if (await userFile.exists()) {
          return await userFile.readAsString();
        }

        // tolerant search inside TxtBooks
        if (await txtDir.exists()) {
          final candidates = txtDir
              .listSync()
              .whereType<File>()
              .where((f) => f.path.toLowerCase().endsWith('.txt'))
              .toList();
          final normTarget = base.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
          File? best;
          for (var c in candidates) {
            final name = c.path.split(Platform.pathSeparator).last;
            final cname = name.replaceAll('.txt', '').toLowerCase();
            final norm = cname.replaceAll(RegExp(r'[^a-z0-9]'), '');
            if (norm == normTarget) {
              best = c;
              break;
            }
          }
          if (best == null) {
            for (var c in candidates) {
              final name = c.path.split(Platform.pathSeparator).last;
              final cname = name.replaceAll('.txt', '').toLowerCase();
              if (cname.contains(base.toLowerCase()) || base.toLowerCase().contains(cname)) {
                best = c;
                break;
              }
            }
          }
          if (best != null) {
            try {
              final raw = await best.readAsString();
              if (raw.trim().isNotEmpty) return raw;
            } catch (_) {}
          }
        }
      } catch (_) {}

      // 2) If no TxtBooks match, try Documents/table_of_contents (but prefer TxtBooks)
      try {
        final tocDir = Directory('${dir.path}/table_of_contents');
        final tocFile = File('${tocDir.path}/$base.txt');
        if (await tocFile.exists()) {
          final raw = await tocFile.readAsString();
          if (raw.trim().isNotEmpty) return raw;
        }
      } catch (_) {}

      // 3) Bundled asset exact match under assets/txt_books
      try {
        final assetPath = 'assets/txt_books/$base.txt';
        final raw = await rootBundle.loadString(assetPath);
        if (raw.trim().isNotEmpty) return raw;
      } catch (_) {}

      // 4) As a last resort, search bundled assets for a tolerant match (manifest scan)
      try {
        final manifestContent = await rootBundle.loadString('AssetManifest.json');
        final Map<String, dynamic> manifest = jsonDecode(manifestContent);
        // check both assets/txt_books and assets/table_of_contents as fallbacks
        final assetEntries = manifest.keys.where((k) => (k.startsWith('assets/txt_books/') || k.startsWith('assets/table_of_contents/')) && k.toLowerCase().endsWith('.txt'));
        final normTarget = base.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
        String? found;
        for (var assetPath in assetEntries) {
          final fileName = assetPath.split('/').last;
          final nameNoExt = fileName.replaceAll('.txt', '').toLowerCase();
          final norm = nameNoExt.replaceAll(RegExp(r'[^a-z0-9]'), '');
          if (norm == normTarget || nameNoExt.contains(base.toLowerCase()) || base.toLowerCase().contains(nameNoExt)) {
            // prefer assets/txt_books entries when both present in manifest
            if (found == null) found = assetPath;
            if (assetPath.startsWith('assets/txt_books/')) {
              found = assetPath;
              break;
            }
          }
        }
        if (found != null) {
          final raw = await rootBundle.loadString(found);
          if (raw.trim().isNotEmpty) return raw;
        }
      } catch (_) {}
    } catch (_) {}
    return null;
  }

  Future<List<Map<String, dynamic>>> _askOpenAiForPageHeadings(
      File book, List<String> pageTexts) async {
    // Capture messenger early to avoid using BuildContext after awaits
    final messenger = ScaffoldMessenger.of(context);
    final key = await _getOpenAiKey();
    if (key == null) {
      messenger.showSnackBar(const SnackBar(
          content:
          Text('OpenAI API key not set. Please add it in Settings.')));
      return [];
    }

    // Build a compact prompt. Truncate page texts to avoid token limits.
    final buffer = StringBuffer();
    buffer.writeln(
        'You are given a PDF book split into pages. For each page produce a concise section heading that best represents the content on that page. Return ONLY a JSON array of objects with keys: "page" (1-based) and "title". Example: [{"page":1,"title":"Introduction"}, ...]');
    buffer.writeln(
        'Do not include any commentary or surrounding text. Ensure JSON parses cleanly.');

    for (var i = 0; i < pageTexts.length; i++) {
      final p = pageTexts[i];
      final snippet = p.length > 1500 ? p.substring(0, 1500) : p;
      buffer.writeln('---PAGE ${i + 1}---');
      buffer.writeln(snippet.replaceAll('\n', ' '));
    }

    final body = {
      'model': 'gpt-3.5-turbo',
      'messages': [
        {
          'role': 'system',
          'content':
          'You are a helpful assistant that extracts section headings from page text.'
        },
        {'role': 'user', 'content': buffer.toString()}
      ],
      'temperature': 0.0,
      'max_tokens': 1500,
    };

    try {
      final prefs = await SharedPreferences.getInstance();
      final proxy = prefs.getString('OPENAI_PROXY_URL') ?? '';
      final appToken = prefs.getString('APP_TOKEN') ?? '';
      http.Response? resp;
      if (proxy.trim().isNotEmpty) {
        final uri = Uri.parse('${proxy.replaceAll(RegExp(r'\\/+$'), '')}/process');
        final proxyBody = jsonEncode({'chunks': [buffer.toString()], 'model': 'gpt-3.5-turbo', 'max_tokens': 1500, 'temperature': 0.0});
        resp = await http.post(uri, headers: {'Content-Type': 'application/json', 'Authorization': 'Bearer $appToken'}, body: proxyBody).timeout(const Duration(seconds: 30));
      } else {
        final client = http.Client();
        resp = await client.post(Uri.parse('https://api.openai.com/v1/chat/completions'), headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $key',
        }, body: jsonEncode(body)).timeout(const Duration(seconds: 30));
        client.close();
      }

      if (resp == null || resp.statusCode != 200) return [];
      final Map<String, dynamic> decoded = jsonDecode(resp.body);
      final content = decoded['choices']?[0]?['message']?['content'] as String? ?? '';

      // Extract JSON array from content
      final jsonStart = content.indexOf('[');
      final jsonEnd = content.lastIndexOf(']');
      if (jsonStart == -1 || jsonEnd == -1) return [];
      final jsonStr = content.substring(jsonStart, jsonEnd + 1);
      final parsed = jsonDecode(jsonStr) as List<dynamic>;
      final results = <Map<String, dynamic>>[];
      for (var item in parsed) {
        try {
          final page = (item['page'] is int)
              ? item['page'] as int
              : int.tryParse(item['page'].toString()) ?? 1;
          final title =
          (item['title'] ?? item['heading'] ?? '').toString();
          results.add({'page': page, 'title': title});
        } catch (_) {}
      }

      if (results.isNotEmpty) {
        await _saveCustomToc(book, results);
      }
      return results;
    } catch (e) {
      return [];
    }
  }

  Future<void> _saveCustomToc(
      File book, List<Map<String, dynamic>> toc) async {
    try {
      final f = await _tocFileForBook(book);
      await f.writeAsString(jsonEncode(toc));
    } catch (_) {}
  }

  void _showTOCInScaffold() async {
    if (_activeBook == null) return;
    final file = _activeBook!;
    final custom = await _loadCustomToc(file);

    // Present a modern left-side panel that slides in, instead of the bottom sheet.
    // Using showGeneralDialog gives us a customizable slide-from-left transition.
    // ignore: use_build_context_synchronously
    await showGeneralDialog<void>(
      context: context,
      barrierLabel: 'TOC',
      barrierDismissible: true,
      barrierColor: Colors.black54,
      transitionDuration: const Duration(milliseconds: 320),
      pageBuilder: (ctx, anim1, anim2) {
        // The actual content is built in the transitionBuilder so keep this empty.
        return const SizedBox.shrink();
      },
      transitionBuilder: (ctx, animation, secondaryAnimation, child) {
        final slide = Tween<Offset>(
            begin: const Offset(-1.0, 0.0), end: Offset.zero)
            .animate(CurvedAnimation(
            parent: animation, curve: Curves.easeOutCubic));
        return SlideTransition(
          position: slide,
          child: Align(
            alignment: Alignment.centerLeft,
            child: FractionallySizedBox(
              widthFactor: 0.86,
              heightFactor: 0.95,
              child: Material(
                color: Colors.white,
                elevation: 16,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
                child: StatefulBuilder(
                    builder: (context, setStateSheet) {
                      int totalPages = 0;
                      try {
                        totalPages = _pdfController.pageCount;
                      } catch (_) {
                        totalPages = 0;
                      }

                      final entries = custom.isNotEmpty
                          ? List<Map<String, dynamic>>.from(custom)
                          : List.generate(
                          (totalPages > 0 ? totalPages : 10),
                              (i) => {
                            'title': 'Page ${i + 1}',
                            'page': i + 1
                          });

                      return Padding(
                        padding: const EdgeInsets.all(14.0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                const Expanded(
                                  child: Text('Table of Contents',
                                      style: TextStyle(
                                          fontSize: 20,
                                          fontWeight: FontWeight.w800)),
                                ),
                                IconButton(
                                  icon: const Icon(Icons.info_outline),
                                  tooltip: 'TOC info',
                                  onPressed: () {
                                    final messenger =
                                    ScaffoldMessenger.of(context);
                                    messenger.showSnackBar(const SnackBar(
                                        content: Text(
                                            'Provide TOC files named <bookname>.txt in Documents/table_of_contents or assets/table_of_contents.')));
                                  },
                                ),
                                IconButton(
                                  icon: const Icon(Icons.close),
                                  onPressed: () =>
                                      Navigator.of(ctx).pop(),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Expanded(
                              child: ListView.separated(
                                itemCount: entries.length,
                                separatorBuilder: (_, __) =>
                                const Divider(height: 1),
                                itemBuilder: (context, index) {
                                  final e = entries[index];
                                  return ListTile(
                                    contentPadding:
                                    const EdgeInsets.symmetric(
                                        horizontal: 8, vertical: 4),
                                    title: Text(e['title'] as String,
                                        style: const TextStyle(
                                            fontWeight: FontWeight.w600)),
                                    subtitle: Text('Page ${e['page']}',
                                        style: TextStyle(
                                            color: Colors.grey[700])),
                                    onTap: () {
                                        try {
                                          _pdfController.jumpToPage(
                                              e['page'] as int);
                                          // Give the viewer a moment to navigate, then show a small
                                          // confirmation so the user knows which section was opened.
                                          Future.delayed(const Duration(milliseconds: 220), () {
                                            try {
                                              ScaffoldMessenger.of(context).showSnackBar(
                                                SnackBar(
                                                  content: Text('${e['title']} — page ${e['page']}'),
                                                  duration: const Duration(seconds: 2),
                                                ),
                                              );
                                            } catch (_) {}
                                          });
                                        } catch (_) {}
                                        Navigator.pop(ctx);
                                    },
                                    trailing: IconButton(
                                      icon: const Icon(Icons.edit, size: 20),
                                      tooltip: 'Edit entry',
                                      onPressed: () async {
                                        final titleCtrl =
                                        TextEditingController(
                                            text:
                                            (e['title'] as String));
                                        final pageCtrl =
                                        TextEditingController(
                                            text: (e['page'] as int)
                                                .toString());
                                        final res =
                                        await showDialog<
                                            Map<String, dynamic>>(
                                          context: context,
                                          builder: (dCtx) => AlertDialog(
                                            title: const Text(
                                                'Edit TOC Entry'),
                                            content: Column(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                TextField(
                                                    controller: titleCtrl,
                                                    decoration:
                                                    const InputDecoration(
                                                        hintText:
                                                        'Section title')),
                                                const SizedBox(height: 8),
                                                TextField(
                                                    controller: pageCtrl,
                                                    decoration:
                                                    const InputDecoration(
                                                        hintText:
                                                        'Page number'),
                                                    keyboardType:
                                                    TextInputType.number),
                                              ],
                                            ),
                                            actions: [
                                              TextButton(
                                                  onPressed: () =>
                                                      Navigator.pop(dCtx),
                                                  child: const Text('Cancel')),
                                              ElevatedButton(
                                                onPressed: () {
                                                  final t = titleCtrl.text
                                                      .trim();
                                                  final p = int.tryParse(
                                                      pageCtrl.text
                                                          .trim()) ??
                                                      1;
                                                  if (t.isEmpty) return;
                                                  Navigator.pop(dCtx, {
                                                    'title': t,
                                                    'page': p
                                                  });
                                                },
                                                child: const Text('Save'),
                                              ),
                                            ],
                                          ),
                                        );

                                        if (res != null) {
                                          setStateSheet(() {
                                            entries[index] = res;
                                          });
                                          await _saveCustomToc(
                                              file,
                                              List<Map<String, dynamic>>.from(
                                                  entries));
                                        }
                                      },
                                    ),
                                  );
                                },
                              ),
                            ),
                            const SizedBox(height: 12),
                            Row(
                              children: [
                                Expanded(
                                  child: ElevatedButton.icon(
                                    icon: const Icon(Icons.add),
                                    label: const Text('Add TOC entry'),
                                    onPressed: () async {
                                      final res = await showDialog<
                                          Map<String, dynamic>>(
                                        context: context,
                                        builder: (dCtx) {
                                          final TextEditingController
                                          titleCtrl =
                                          TextEditingController();
                                          final TextEditingController
                                          pageCtrl =
                                          TextEditingController();
                                          return AlertDialog(
                                            title: const Text(
                                                'Add TOC Entry'),
                                            content: Column(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                TextField(
                                                    controller: titleCtrl,
                                                    decoration:
                                                    const InputDecoration(
                                                        hintText:
                                                        'Section title')),
                                                const SizedBox(height: 8),
                                                TextField(
                                                    controller: pageCtrl,
                                                    decoration:
                                                    const InputDecoration(
                                                        hintText:
                                                        'Page number'),
                                                    keyboardType:
                                                    TextInputType.number),
                                              ],
                                            ),
                                            actions: [
                                              TextButton(
                                                  onPressed: () =>
                                                      Navigator.pop(dCtx),
                                                  child: const Text('Cancel')),
                                              ElevatedButton(
                                                onPressed: () {
                                                  final t = titleCtrl.text
                                                      .trim();
                                                  final p = int.tryParse(
                                                      pageCtrl.text
                                                          .trim()) ??
                                                      1;
                                                  if (t.isEmpty) return;
                                                  Navigator.pop(dCtx, {
                                                    'title': t,
                                                    'page': p
                                                  });
                                                },
                                                child: const Text('Add'),
                                              ),
                                            ],
                                          );
                                        },
                                      );

                                      if (res != null) {
                                        setStateSheet(() {
                                          custom.add(res);
                                        });
                                        await _saveCustomToc(file, custom);
                                      }
                                    },
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      );
                    }),
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey[50],
      appBar: _activeBook == null
          ? AppBar(
              title: const Text('E-Book Library',
                  style: TextStyle(
                      fontWeight: FontWeight.w900,
                      fontSize: 18
                  )),
              actions: [
                IconButton(
                  icon: const Icon(Icons.bookmarks_outlined),
                  tooltip: 'Bookmarks',
                  onPressed: () async {
                    final result = await Navigator.of(context).push(
                        MaterialPageRoute(
                            builder: (_) => BookmarksPage(
                                  bookmarks: _bookmarks.toList(),
                                  onOpen: (path) {
                                    final f = _allBooks.firstWhere(
                                        (b) => b.path == path,
                                        orElse: () => File(path));
                                    _openBook(f);
                                  },
                                  onRemove: (path) {
                                    setState(() {
                                      _bookmarks.remove(path);
                                    });
                                  },
                                )));
                  },
                ),
                IconButton(
                  icon: const Icon(Icons.bug_report),
                  tooltip: 'Debug QA',
                  onPressed: () {
                    Navigator.of(context).push(MaterialPageRoute(builder: (_) => const DebugQaListPage()));
                  },
                ),
                IconButton(
                  icon: const Icon(Icons.sync_outlined),
                  tooltip: 'Sync now',
                  onPressed: () async {
                    final s = FirebaseSync(
                        'https://tashahit400-default-rtdb.asia-southeast1.firebasedatabase.app/');
                    ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Starting sync...')));
                    try {
                      final unsyncedBefore = await s.getUnsyncedCount();
                      final uploaded = await s.uploadUnsynced();
                      await s.downloadAndMerge();
                      final unsyncedAfter = await s.getUnsyncedCount();
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                          content: Text(
                              'Sync done: uploaded $uploaded, unsynced before=$unsyncedBefore, after=$unsyncedAfter')));
                    } catch (e) {
                      ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('Sync failed: $e')));
                    }
                  },
                ),
                IconButton(
                  icon: const Icon(Icons.notifications_none_rounded),
                  onPressed: () => setState(() => _currentIndex = 1),
                ),
                IconButton(
                  icon: const Icon(Icons.bug_report_outlined),
                  tooltip: 'Asset diagnostics',
                  onPressed: _showAssetDiagnostics,
                ),
                IconButton(
                  icon: const Icon(Icons.file_download),
                  tooltip: 'Force import assets',
                  onPressed: () async {
                    await _forceImportAssets();
                  },
                ),
              ],
            )
          : AppBar(
              toolbarHeight: 115,
              backgroundColor: const Color(0xFF0B5394),
              elevation: 8,
              flexibleSpace: Container(
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFF0B5394), Color(0xFF1565C0)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.15),
                      blurRadius: 8,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Book Name
                        Flexible(
                          child: Text(
                            _stripPdfExt(_activeBook!.path.split(Platform.pathSeparator).last),
                            overflow: TextOverflow.ellipsis,
                            maxLines: 1,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              fontWeight: FontWeight.w800,
                              fontSize: 20,
                              color: Colors.white,
                              letterSpacing: 0.5,
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        // Centered Tool Buttons
                        SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _buildToolButton(
                                icon: Icons.menu_book,
                                tooltip: 'Table of Contents',
                                onPressed: _showTOCInScaffold,
                              ),
                              _buildToolButton(
                                icon: Icons.auto_fix_high,
                                tooltip: 'Train book',
                                onPressed: () async {
                                  if (_activeBook == null) return;
                                  await _trainActiveBook();
                                },
                              ),
                              _buildToolButton(
                                icon: Icons.layers_outlined,
                                tooltip: 'View chunks',
                                onPressed: () {
                                  if (_activeBook != null) {
                                    final bookId = _activeBook!.path.split(Platform.pathSeparator).last;
                                    final bookName = bookId.replaceAll(RegExp(r'\.pdf$'), '').replaceAll(RegExp(r'[_-]'), ' ');
                                    Navigator.of(context).push(
                                      MaterialPageRoute(
                                        builder: (_) => ChunksViewerPage(
                                          bookId: bookId,
                                          bookName: bookName,
                                        ),
                                      ),
                                    );
                                  }
                                },
                              ),
                              _buildToolButton(
                                icon: _pdfBookmarked
                                    ? Icons.bookmark
                                    : Icons.bookmark_border,
                                tooltip: _pdfBookmarked ? 'Remove bookmark' : 'Add bookmark',
                                onPressed: _toggleBookmarkForActive,
                              ),
                              _buildToolButton(
                                icon: Icons.close,
                                tooltip: 'Close book',
                                onPressed: _closeBook,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
      body: SafeArea(
        child: Padding(
          padding: _activeBook != null
              ? EdgeInsets.zero
              : const EdgeInsets.symmetric(horizontal: 20),
          child: _activeBook != null
              ? Column(
            children: [
              const SizedBox(height: 12),
              Expanded(
                child: Card(
                  margin: EdgeInsets.zero,
                  elevation: 6,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(0)),
                  clipBehavior: Clip.hardEdge,
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: SfPdfViewer.file(
                          _activeBook!,
                          controller: _pdfController,
                          canShowScrollHead: true,
                          canShowScrollStatus: true,
                          onDocumentLoaded: (details) {
                            if (mounted) {
                              setState(() {
                                _isPdfLoading = false;
                              });
                            }
                          },
                          onDocumentLoadFailed: (error) {
                            if (mounted) {
                              setState(() {
                                _isPdfLoading = false;
                              });
                            }
                            ScaffoldMessenger.of(context)
                                .showSnackBar(SnackBar(
                                content: Text(
                                    'Failed to load PDF: $error')));
                          },
                          // fill available width and height by using BoxFit-like behavior is internal to the viewer
                        ),
                      ),
                      if (_isPdfLoading)
                        const Positioned.fill(
                          child: ColoredBox(
                            color: Color.fromRGBO(255, 255, 255, 0.9),
                            child:
                            Center(child: CircularProgressIndicator()),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          )
              : (_currentIndex == 0
              ? Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 24),
              TextField(
                controller: _searchController,
                decoration: InputDecoration(
                  hintText: 'Search books...',
                  prefixIcon: const Icon(Icons.search,
                      color: Colors.grey),
                  filled: true,
                  fillColor: Colors.white,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                    borderSide: BorderSide.none,
                  ),
                  contentPadding:
                  const EdgeInsets.symmetric(vertical: 16),
                ),
              ),
              const SizedBox(height: 24),
              Text(
                'My Library',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 16),
              Expanded(
                child: _filteredBooks.isEmpty
                    ? Center(
                  child: Column(
                    mainAxisAlignment:
                    MainAxisAlignment.center,
                    children: [
                      Icon(Icons.search_off_rounded,
                          size: 64,
                          color: Colors.grey[300]),
                      const SizedBox(height: 16),
                      Text(
                        'No books found\n_filteredBooks.length=${_filteredBooks.length}\n_allBooks.length=${_allBooks.length}',
                        style: TextStyle(
                            color: Colors.grey[500]),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 16),
                      ElevatedButton(
                        onPressed: () {
                          print('[DEBUG] Refresh button tapped. _allBooks=${_allBooks.length}, _filteredBooks=${_filteredBooks.length}');
                          _loadBooks();
                        },
                        child: const Text('Refresh'),
                      ),
                    ],
                  ),
                )
                    : RefreshIndicator(
                  onRefresh: () async {
                    await _loadBooks();
                  },
                  child: ListView.separated(
                  padding:
                  const EdgeInsets.only(bottom: 16),
                  itemCount: _filteredBooks.length,
                  separatorBuilder: (_, __) =>
                  const SizedBox(height: 12),
                  itemBuilder: (context, index) {
                    final book = _filteredBooks[index];
                    final bookName = book.path
                        .split(Platform.pathSeparator)
                        .last;
                    final base = _stripPdfExt(bookName);
                    final imageAsset =
                        'assets/images/${base}.png';
                    String? localImagePath;
                    try {
                      final dir =
                          book.parent.path; // BooksSource
                      final candidate =
                          '${dir}${Platform.pathSeparator}$base.png';
                      final f = File(candidate);
                      if (f.existsSync()) {
                        localImagePath = candidate;
                      }
                    } catch (_) {}
                    final isBookmarked =
                    _bookmarks.contains(book.path);
                    return BookCard(
                      title: bookName,
                      imageAsset: imageAsset,
                      localImagePath: localImagePath,
                      pdfPath: book.path,
                      onTap: () => _openBook(book),
                      onLongPress: () async {
                        try {
                          await Clipboard.setData(ClipboardData(text: book.path));
                          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                              content: Text('Book path copied to clipboard')));
                        } catch (_) {
                          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                              content: Text('Could not copy path')));
                        }
                      },
                      trailing: PopupMenuButton<String>(
                        tooltip: 'Options',
                        icon: const Icon(Icons.more_vert),
                        onSelected: (v) async {
                          if (v == 'delete') {
                            final confirm =
                            await showDialog<bool?>(
                                context: context,
                                builder: (ctx) =>
                                    AlertDialog(
                                      title: const Text(
                                          'Delete book?'),
                                      content: Text(
                                          'Delete "$bookName" and its related files from device? This cannot be undone.'),
                                      actions: [
                                        TextButton(
                                            onPressed: () =>
                                                Navigator.pop(
                                                    ctx,
                                                    false),
                                            child: const Text(
                                                'Cancel')),
                                        TextButton(
                                            onPressed: () =>
                                                Navigator.pop(
                                                    ctx,
                                                    true),
                                            child: const Text(
                                                'Delete'))
                                      ],
                                    ));
                            if (confirm == true) {
                              await _deleteBookFiles(book);
                            }
                          } else if (v == 'bookmark') {
                            _toggleBookmark(book);
                          }
                        },
                        itemBuilder: (_) => [
                          const PopupMenuItem(
                              value: 'delete',
                              child: Text('Delete')),
                          PopupMenuItem(
                              value: 'bookmark',
                              child: Text(isBookmarked
                                  ? 'Remove bookmark'
                                  : 'Add bookmark')),
                        ],
                      ),
                    );
                  },
                ),
              ), )],
          )
              : (_currentIndex == 1
              ? const UpdatesPage()
              : const SettingsPage())),
        ),
      ),
      bottomNavigationBar: AppFooter(
        selectedIndex: _currentIndex,
        onDestinationSelected: (index) {
          if (index == 2) {
            Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => const SettingsPage(),
            ));
            return;
          }
          setState(() {
            _currentIndex = index;
            _activeBook = null; // close any open book when switching tabs
          });
        },
      ),
      floatingActionButton: _activeBook != null
          ? FloatingActionButton(
              onPressed: () async {
                // Book is open, so use it as the selected book
                final selectedBookForChat =
                    _activeBook!.path.split(Platform.pathSeparator).last;

                // Let user choose Online or Offline chat
                final choice = await showChatModeDialog(context);

                if (choice == 'online') {
                  // ignore: use_build_context_synchronously
                  showDialog(
                      context: context,
                      builder: (_) => ChatBotDialog(
                          bookCount: _filteredBooks.length,
                          selectedBook: selectedBookForChat));
                } else if (choice == 'offline') {
                  // ignore: use_build_context_synchronously
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => OfflineChatBotPage(
                        selectedBook: selectedBookForChat,
                      ),
                    ),
                  );
                }
              },
              child: const Icon(Icons.chat),
            )
          : null,
    );
  }
}

// ---------------- Bookmarks Page ----------------
class BookmarksPage extends StatelessWidget {
  final List<String> bookmarks; // file paths
  final void Function(String path) onOpen;
  final void Function(String path) onRemove;

  const BookmarksPage(
      {super.key,
        required this.bookmarks,
        required this.onOpen,
        required this.onRemove});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Bookmarks'),
        backgroundColor: Colors.white,
        foregroundColor: Colors.black,
        elevation: 0,
      ),
      body: bookmarks.isEmpty
          ? Center(
          child: Text('No bookmarks',
              style: TextStyle(color: Colors.grey[600])))
          : ListView.separated(
        padding: const EdgeInsets.all(12),
        itemCount: bookmarks.length,
        separatorBuilder: (_, __) => const SizedBox(height: 8),
        itemBuilder: (ctx, i) {
          final path = bookmarks[i];
          final name = path.split(Platform.pathSeparator).last;
          return ListTile(
            tileColor: Colors.white,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10)),
            leading: ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: Image.asset(
                    'assets/images/${_stripPdfExt(name)}.png',
                    width: 56,
                    height: 72,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => Container(
                        width: 56,
                        height: 72,
                        color: Colors.grey[200],
                        child: const Icon(Icons.menu_book_rounded,
                            color: Colors.grey)))),
            title:
            Text(name, style: const TextStyle(fontWeight: FontWeight.w600)),
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              IconButton(
                  icon: const Icon(Icons.open_in_new),
                  onPressed: () {
                    onOpen(path);
                    Navigator.of(context).pop();
                  }),
              IconButton(
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () {
                    onRemove(path);
                  }),
            ]),
          );
        },
      ),
    );
  }
}

// ---------------- Book Card ----------------

class BookCard extends StatefulWidget {
  final String title;
  final String? imageAsset; // optional asset path for cover image
  final String? localImagePath; // optional local image file path (prefer this if present)
  final String? pdfPath; // optional PDF file path to generate thumbnail
  final VoidCallback onTap;
  final Widget? trailing;
  final VoidCallback? onLongPress;

  const BookCard({
    super.key,
    required this.title,
    this.imageAsset,
    this.localImagePath,
    this.pdfPath,
    required this.onTap,
    this.trailing,
    this.onLongPress,
  });

  @override
  State<BookCard> createState() => _BookCardState();
}

class _BookCardState extends State<BookCard> {
  Future<Uint8List?>? _pdfThumbnailFuture;

  @override
  void initState() {
    super.initState();
    // Generate PDF thumbnail if available
    if (widget.pdfPath != null && widget.localImagePath == null && widget.imageAsset == null) {
      _pdfThumbnailFuture = _generatePdfThumbnail(widget.pdfPath!);
    }
  }

  Future<Uint8List?> _generatePdfThumbnail(String pdfPath) async {
    try {
      final file = File(pdfPath);
      if (!await file.exists()) return null;

      // Use pdf_render APIs
      final doc = await pdf_render.PdfDocument.openFile(pdfPath);
      if (doc.pageCount < 1) {
        await doc.dispose();
        return null;
      }
      final page = await doc.getPage(1);
      final pageImage = await page.render(
        width: 300,
        height: 400,
      );
      if (pageImage == null) {
        await doc.dispose();
        return null;
      }
      final image = await pageImage.createImageIfNotAvailable();
      if (image == null) {
        await doc.dispose();
        return null;
      }
      final pngBytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await doc.dispose();
      return pngBytes?.buffer.asUint8List();
    } catch (e) {
      print('[BookCard] PDF thumbnail generation failed: $e');
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 4),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          boxShadow: [
            BoxShadow(
              color: const Color.fromRGBO(158, 158, 158, 0.08),
              blurRadius: 12,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Row(
          children: [
            Container(
              width: 96,
              height: 96,
              margin: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Builder(builder: (ctx) {
                  try {
                    if (widget.localImagePath != null) {
                      final f = File(widget.localImagePath!);
                      if (f.existsSync()) {
                        return Image.file(f, fit: BoxFit.cover);
                      }
                    }
                  } catch (_) {}
                  if (widget.imageAsset != null) {
                    return Image.asset(
                      widget.imageAsset!,
                      fit: BoxFit.cover,
                      errorBuilder: (ctx, err, st) => _buildPlaceholder(),
                    );
                  }
                  
                  // Show PDF thumbnail if available
                  if (_pdfThumbnailFuture != null) {
                    return FutureBuilder<Uint8List?>(
                      future: _pdfThumbnailFuture,
                      builder: (ctx, snapshot) {
                        if (snapshot.hasData && snapshot.data != null) {
                          return Image.memory(snapshot.data!, fit: BoxFit.cover);
                        }
                        return _buildPlaceholder();
                      },
                    );
                  }
                  
                  return _buildPlaceholder();
                }),
              ),
            ),
            Expanded(
              child: Padding(
                padding:
                const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      widget.title,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 6),
                    Text('PDF Document',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.grey[600])),
                  ],
                ),
              ),
            ),
            if (widget.trailing != null)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: widget.trailing,
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildPlaceholder() {
    return Container(
      color: Colors.grey[200],
      child: const Center(
          child: Icon(Icons.menu_book_rounded,
              color: Colors.grey, size: 36)),
    );
  }
}

// Modern centered dialog to pick a book from a list of Files.
// Returns the selected filename (not full path) or null if cancelled.
Future<String?> showBookPickerDialog(
    BuildContext context, List<File> files,
    {String title = 'Select a book'}) {
  return showDialog<String?>(
    context: context,
    builder: (ctx) {
      return Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: SizedBox(
          width: min(760, MediaQuery.of(ctx).size.width * 0.9),
          height: min(620, MediaQuery.of(ctx).size.height * 0.85),
          child: StatefulBuilder(builder: (ctx, setState) {
            String query = '';
            List<File> filtered = files;

            void doFilter(String q) {
              query = q;
              filtered = files
                  .where((f) => f.path
                  .split(Platform.pathSeparator)
                  .last
                  .toLowerCase()
                  .contains(q.toLowerCase()))
                  .toList();
              setState(() {});
            }

            return Column(
              children: [
                Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 12),
                    child: Row(children: [
                      Expanded(
                          child: Text(title,
                              style: const TextStyle(
                                  fontSize: 18, fontWeight: FontWeight.w700))),
                      IconButton(
                          icon: const Icon(Icons.close),
                          onPressed: () => Navigator.pop(ctx, null))
                    ])),
                Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: TextField(
                        decoration: InputDecoration(
                            prefixIcon: const Icon(Icons.search),
                            hintText: 'Search books...'),
                        onChanged: doFilter)),
                const SizedBox(height: 8),
                Expanded(
                  child: filtered.isEmpty
                      ? Center(
                      child: Text('No books found',
                          style: TextStyle(color: Colors.grey[600])))
                      : ListView.separated(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 8),
                    itemCount: filtered.length,
                    separatorBuilder: (_, __) =>
                    const SizedBox(height: 8),
                    itemBuilder: (c, i) {
                      final f = filtered[i];
                      final name = f.path
                          .split(Platform.pathSeparator)
                          .last;
                      final base = _stripPdfExt(name);
                      final asset = 'assets/images/$base.png';
                      return InkWell(
                        onTap: () => Navigator.pop(ctx, name),
                        borderRadius: BorderRadius.circular(12),
                        child: Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(12),
                              color: Colors.white,
                              boxShadow: [
                                BoxShadow(
                                    color: Colors.black12,
                                    blurRadius: 6,
                                    offset: const Offset(0, 2))
                              ]),
                          child: Row(children: [
                            ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: Image.asset(asset,
                                    width: 56,
                                    height: 72,
                                    fit: BoxFit.cover,
                                    errorBuilder: (_, __, ___) =>
                                        Container(
                                            width: 56,
                                            height: 72,
                                            color: Colors.grey[200],
                                            child: const Icon(
                                                Icons.menu_book_rounded,
                                                color: Colors.grey)))),
                            const SizedBox(width: 12),
                            Expanded(
                                child: Text(name,
                                    style: const TextStyle(
                                        fontWeight: FontWeight.w600))),
                            const SizedBox(width: 8),
                            const Icon(Icons.chevron_right,
                                color: Colors.black38),
                          ]),
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(height: 12),
              ],
            );
          }),
        ),
      );
    },
  );
}

// Modern centered dialog to pick chat mode (online / offline). Returns 'online'|'offline' or null.
Future<String?> showChatModeDialog(BuildContext context) {
  return showDialog<String?>(
    context: context,
    builder: (ctx) {
      return Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: SizedBox(
          width: min(560, MediaQuery.of(ctx).size.width * 0.9),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Row(children: [
                Expanded(
                    child: Text('Choose chat mode',
                        style: const TextStyle(
                            fontSize: 18, fontWeight: FontWeight.w700))),
                IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(ctx, null))
              ]),
              const SizedBox(height: 8),
              ListTile(
                leading: CircleAvatar(
                    backgroundColor: Colors.blue[600],
                    child: const Icon(Icons.cloud, color: Colors.white)),
                title: const Text('Online Chat'),
                subtitle: const Text(
                    'Use OpenAI for live answers (requires API key & internet)'),
                onTap: () => Navigator.pop(ctx, 'online'),
              ),
              ListTile(
                leading: CircleAvatar(
                    backgroundColor: Colors.green[600],
                    child: const Icon(Icons.offline_bolt, color: Colors.white)),
                title: const Text('Offline Chat'),
                subtitle: const Text('Use your saved Q/A and indexed content'),
                onTap: () => Navigator.pop(ctx, 'offline'),
              ),
              const SizedBox(height: 12),
            ]),
          ),
        ),
      );
    },
  );
}

// ---------------- Modern PDF Viewer Page ----------------
class PdfViewerPage extends StatefulWidget {
  final File file;

  const PdfViewerPage({super.key, required this.file});

  @override
  State<PdfViewerPage> createState() => _PdfViewerPageState();
}

class _PdfViewerPageState extends State<PdfViewerPage> {
  late PdfViewerController _pdfController;
  bool _bookmarked = false;
  bool _isLoading = true;

  // Attempt to find the page number for a query string by scanning PDF text per page.
  Future<int?> _findPageForQuery(String query) async {
    try {
      final bytes = await widget.file.readAsBytes();
      final doc = PdfDocument(inputBytes: bytes);
      final pageCount = doc.pages.count;
      for (var i = 0; i < pageCount; i++) {
        try {
          final txt = (PdfTextExtractor(doc) as dynamic)
              .extractText(startPage: i + 1, endPage: i + 1) as String? ??
              '';
          if (txt.toLowerCase().contains(query.toLowerCase())) {
            doc.dispose();
            return i + 1;
          }
        } catch (_) {}
      }
      doc.dispose();
    } catch (e) {
      print('[TOC][Search] failed: $e');
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    _pdfController = PdfViewerController();
    _isLoading = true;
  }

  void _showTOC() {
    // Try to load a user-provided TOC from Documents/table_of_contents/<base>.txt
    Future<List<Map<String, dynamic>>> _loadTocEntries() async {
      try {
        final fileName = widget.file.path.split(Platform.pathSeparator).last;
        final base = _stripPdfExt(fileName);
        final dir = await getApplicationDocumentsDirectory();
        final tocFile = File('${dir.path}/table_of_contents/$base.txt');
        if (await tocFile.exists()) {
          final raw = await tocFile.readAsString();
          final lines = raw
              .split(RegExp(r'\r?\n'))
              .map((s) => s.trim())
              .where((s) => s.isNotEmpty)
              .toList();
          final pageRegex = RegExp(r'(\d{1,4})\s*$');
          final entries = <Map<String, dynamic>>[];
          for (var line in lines) {
            if (line.toLowerCase().contains('table of contents')) continue;
            final m = pageRegex.firstMatch(line);
            if (m != null) {
              final page = int.tryParse(m.group(1) ?? '') ?? 1;
              final title = line
                  .substring(0, m.start)
                  .replaceAll(RegExp(r'[\.\s]+\$'), '')
                  .trim();
              if (title.isNotEmpty && page > 0) {
                entries.add({'title': title, 'page': page});
              }
            } else {
              // No explicit page number - keep entry with null page for user to locate
              entries.add({'title': line, 'page': null});
            }
          }
          if (entries.isNotEmpty) return entries;
        }
      } catch (e) {
        // ignore and fallback
      }
      // Fallback: build a simple page list from the PDF page count
      int total = 0;
      try {
        total = _pdfController.pageCount;
      } catch (_) {
        total = 10; // safety fallback
      }
      return List.generate(
          total, (i) => {'title': 'Page ${i + 1}', 'page': i + 1});
    }

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => FutureBuilder<List<Map<String, dynamic>>>(
        future: _loadTocEntries(),
        builder: (context, snap) {
          final entries = snap.data ?? [];
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 12.0, horizontal: 8.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    const Expanded(
                        child: Text('Table of contents',
                            style: TextStyle(
                                fontSize: 18, fontWeight: FontWeight.w700))),
                    IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: () => Navigator.pop(context)),
                  ],
                ),
                const SizedBox(height: 8),
                if (snap.connectionState != ConnectionState.done)
                  const LinearProgressIndicator(),
                Flexible(
                  child: entries.isEmpty
                      ? Center(
                      child: Text('No table of contents available',
                          style: TextStyle(color: Colors.grey[700])))
                      : ListView.separated(
                    shrinkWrap: true,
                    itemCount: entries.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (c, i) {
                      final e = entries[i];
                      final page = e['page'] as int?;
                      return ListTile(
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 6),
                        leading: CircleAvatar(
                            backgroundColor: Colors.deepPurple[50],
                            child: page != null
                                ? Text('${page}',
                                style: const TextStyle(
                                    color: Colors.deepPurple))
                                : const Icon(Icons.search,
                                color: Colors.deepPurple)),
                        title: Text(e['title'] as String,
                            style: const TextStyle(
                                fontWeight: FontWeight.w600)),
                        subtitle: page != null
                            ? Text('Page ${page}',
                            style: TextStyle(
                                color: Colors.grey[600], fontSize: 12))
                            : Text('Page: unknown',
                            style: TextStyle(
                                color: Colors.grey[500],
                                fontSize: 12)),
                        trailing: page == null
                            ? IconButton(
                            icon: const Icon(Icons.search),
                            tooltip: 'Locate in document',
                            onPressed: () async {
                              // Attempt to auto-locate by searching PDF text
                              final found = await _findPageForQuery(
                                  e['title'] as String);
                              if (found != null) {
                                try {
                                  _pdfController.jumpToPage(found);
                                } catch (_) {}
                                Navigator.pop(context);
                              } else {
                                ScaffoldMessenger.of(context)
                                    .showSnackBar(const SnackBar(
                                    content: Text(
                                        'Could not auto-locate entry in document.')));
                              }
                            })
                            : null,
                        onTap: page != null
                            ? () {
                          try {
                            _pdfController.jumpToPage(page);
                          } catch (_) {}
                          Navigator.pop(context);
                        }
                            : null,
                      );
                    },
                  ),
                ),
                const SizedBox(height: 12),
              ],
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey[100],
      appBar: AppBar(
        backgroundColor: Colors.deepPurple,
        elevation: 0,
        titleSpacing: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Book name at the top
            Padding(
              padding: const EdgeInsets.only(left: 16, top: 8, right: 16),
              child: Text(
                widget.file.path.split(Platform.pathSeparator).last,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 18,
                ),
              ),
            ),
            // Buttons below the name
            Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.menu_book_outlined),
                  onPressed: _showTOC,
                  tooltip: 'Table of Contents',
                ),
                IconButton(
                  icon: const Icon(Icons.share_outlined),
                  onPressed: () {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Share feature coming soon!')),
                    );
                  },
                  tooltip: 'Share',
                ),
              ],
            ),
          ],
        ),
      ),
      body: Stack(
        children: [
          SfPdfViewer.file(
            widget.file,
            controller: _pdfController,
            canShowScrollHead: true,
            canShowScrollStatus: true,
            onDocumentLoaded: (details) {
              setState(() => _isLoading = false);
            },
            onDocumentLoadFailed: (error) {
              setState(() => _isLoading = false);
              ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Failed to load PDF: $error')));
            },
          ),
          if (_isLoading)
            const Positioned.fill(
              child: ColoredBox(
                color: Color.fromRGBO(255, 255, 255, 0.9),
                child: Center(child: CircularProgressIndicator()),
              ),
            ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: Colors.deepPurple,
        child: Icon(_bookmarked ? Icons.bookmark : Icons.bookmark_border),
        onPressed: () {
          setState(() => _bookmarked = !_bookmarked);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content:
              Text(_bookmarked ? 'Bookmarked' : 'Removed bookmark'),
              duration: const Duration(seconds: 1),
            ),
          );
        },
      ),
    );
  }
}

// ---------------- ChatBot Dialog ----------------
class ChatBotDialog extends StatefulWidget {
  final int bookCount;
  final String? selectedBook; // book id (filename) to scope queries
  const ChatBotDialog(
      {super.key, this.bookCount = 0, this.selectedBook});

  @override
  State<ChatBotDialog> createState() => _ChatBotDialogState();
}

class _ChatBotDialogState extends State<ChatBotDialog> {
  final TextEditingController _messageController = TextEditingController();
  String _response = '';
  bool _isLoading = false;
  bool _isUploading = false;
  double? _uploadProgress;
  String? _selectedBook;
  final List<Map<String, dynamic>> _messages = [];
  final ScrollController _scrollController = ScrollController();
  String? _sessionId;
  List<Map<String, dynamic>> _sessionsList = [];
  String? _matchedTxtFile; // name/path of the TXT file used for fallback

  // Cached API key read from SharedPreferences (or dart-define fallback)
  String? _cachedApiKey;

  // Reuse a single http.Client for the dialog lifetime to avoid repeated handshakes
  final http.Client _client = http.Client();

  // Provide your OpenAI key through dart-define as a fallback.
  static const String _envApiKey =
  String.fromEnvironment('OPENAI_API_KEY', defaultValue: '');

  Future<void> _ensureCachedKey() async {
    if (_cachedApiKey != null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString('OPENAI_API_KEY');
      if (saved != null && saved.trim().isNotEmpty) {
        _cachedApiKey = saved.trim();
        return;
      }
    } on PlatformException catch (_) {
      // Could not access platform channel for SharedPreferences; fall back to env define
    } catch (_) {
      // ignore other errors and fallback
    }

    if (_envApiKey.isNotEmpty) {
      _cachedApiKey = _envApiKey;
    }
  }

  // Heuristic: determine whether a user question should be answered strictly
  // from the selected book (i.e., requires grounding). This catches summary
  // and book-specific intents like "tell me about this book", "what does
  // this book say about X", chapter/page requests, or explicit "according
  // to the book" phrasing.
  bool _isBookScopedQuestion(String message) {
    try {
      final m = message.toLowerCase();
      if (m.contains('tell me about') ||
          m.contains('tell me about this book') ||
          m.contains('what is this book') ||
          m.contains('what is the book about') ||
          m.contains('describe the book') ||
          m.contains('give me an overview') ||
          m.contains('give me a summary') ||
          m.contains('summar') ||
          m.contains('table of contents') ||
          m.contains('list the chapters') ||
          m.contains('chapter') ||
          m.contains('page') ||
          m.contains('according to the book') ||
          m.contains('in this book') ||
          m.contains('what does the book say') ||
          m.contains('what does this book say') ||
          m.contains('according to this book')) {
        return true;
      }
    } catch (_) {}
    return false;
  }

  // Detect RagService 'not found' style answers so we can fall back to a
  // general OpenAI answer when the book doesn't contain the info.
  bool _isNotFoundAnswer(String text) {
    try {
      final t = text.toString().toLowerCase();
      if (t.contains('not found in books') || t.contains('no relevant information found') || t.contains('not found in book')) return true;
    } catch (_) {}
    return false;
  }

  Future<Map<String, dynamic>> _sendMessage(String message) async {
    setState(() {
      _isLoading = true;
    });
    String answer = '';
    List<Map<String, dynamic>> citations = [];
    List<String> bullets = [];
    await _ensureCachedKey();
    final keyToUse = _cachedApiKey ?? '';

    // Quick connectivity check: try a fast DNS lookup to decide offline behavior
    bool online = true;
    try {
      final res = await InternetAddress.lookup('example.com')
          .timeout(const Duration(seconds: 3));
      online = res.isNotEmpty && res[0].rawAddress.isNotEmpty;
    } catch (_) {
      online = false;
    }

    // Normalize and prepare book-scoped query: prefix question with book name so cached embeddings are per-book+question
    final bookId = _selectedBook ?? widget.selectedBook;
    final combinedQuery = (bookId != null) ? '[$bookId] $message' : message;

    // If user asks what book is selected, reply locally
    final ml = message.toLowerCase();
    if (ml.contains('what book') ||
        ml.contains('which book') ||
        ml.contains('what book have i selected') ||
        ml.contains('which book did i select')) {
      final ans = bookId ?? 'No book selected';
      if (mounted) {
        setState(() {
          _response = ans;
          _isLoading = false;
        });
      }
      return {'answer': ans, 'citations': <Map<String, dynamic>>[]};
    }

    // Determine whether this question should be answered strictly from the selected book
    final bool wantsBookSummary = _isBookScopedQuestion(message);

    if (wantsBookSummary && (_selectedBook ?? widget.selectedBook) == null) {
      final ans = 'Please select a book first so I can summarize it.';
      if (mounted) {
        setState(() {
          _response = ans;
          _isLoading = false;
        });
      }
      return {'answer': ans, 'citations': <Map<String, dynamic>>[]};
    }

    if (keyToUse.isNotEmpty && online) {
      try {
        // If a book is selected, attempt to include its indexed excerpts (chunks) in the prompt.
        final backend = await BackendConfig.getInstance();
        final embSvc = EmbeddingService(backend);
        final rag = RagService(embSvc, backend);

        if (bookId != null) {
          try {
            final chunks = await rag.retrieve(message, topK: 8, book: bookId);
            if (chunks.isNotEmpty) {
                  // Ask OpenAI using the retrieved excerpts (book-grounded)
                  final res = await rag.answerWithOpenAI('Book: ${bookId}\nQuestion: $message', chunks);
                  answer = (res['answer'] ?? '').toString();
                  // Reinforcement: if retrieved evidence is weak (low similarity), attempt one refinement
                  try {
                    // Compute max chunk similarity score if available (retrieve returns maps with 'score')
                    double maxScore = 0.0;
                    for (var c in chunks) {
                      try {
                        final s = (c['score'] as num?)?.toDouble() ?? 0.0;
                        if (s > maxScore) maxScore = s;
                      } catch (_) {}
                    }
                    const double _minGoodScore = 0.18; // tunable threshold
                    if (maxScore < _minGoodScore && keyToUse.isNotEmpty) {
                      // Try one refinement: ask the model to improve/clarify the previous answer
                      final refineQuestion =
                          'Book: ${bookId}\nQuestion: $message\nPreviousAnswer: ${answer}\n\nInstruction: The supporting excerpts show low similarity to the question. Please attempt to improve or clarify the previous answer using ONLY the provided excerpts. If you cannot improve because the excerpts do not contain relevant information, respond with exactly "No relevant information found in the selected book."';
                      try {
                        final refined = await rag.answerWithOpenAI(refineQuestion, chunks);
                        final refinedAnswer = (refined['answer'] ?? '').toString();
                        if (refinedAnswer.isNotEmpty && refinedAnswer.trim() != answer.trim()) {
                          answer = refinedAnswer;
                          // show gentle feedback to user that answer was refined and cached
                          try {
                            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Refined answer saved for future queries')));
                          } catch (_) {}
                        }
                      } catch (e) {
                        // ignore refinement errors — keep original answer
                        print('[Main] refinement attempt failed: $e');
                      }
                    }
                  } catch (_) {}
                  // capture citations and bullets parsed by RagService (and returned)
              try {
                final rc = res['citations'];
                if (rc is Iterable) {
                  citations = rc.map((e) => (e as Map).cast<String, dynamic>()).toList();
                } else {
                  citations = List<Map<String, dynamic>>.from(rag.lastCitations);
                }
              } catch (_) {
                citations = List<Map<String, dynamic>>.from(rag.lastCitations);
              }
              try {
                final rb = res['bullets'];
                if (rb is Iterable) bullets = rb.map((e) => e.toString()).toList();
                else bullets = List<String>.from(rag.lastBullets);
              } catch (_) {
                bullets = List<String>.from(rag.lastBullets);
              }

              // If RagService explicitly reported the answer is NOT FOUND in
              // the book, then fall back to a general OpenAI answer so the
              // user still receives a helpful response (not grounded).
              try {
                if (_isNotFoundAnswer(answer) && keyToUse.isNotEmpty) {
                  final direct = await _askOpenAiDirectly(message, bookId ?? '', keyToUse);
                  final directAns = (direct['answer'] ?? '') as String? ?? '';
                  if (directAns.trim().isNotEmpty) {
                    answer = directAns;
                    // clear citations because this direct answer isn't book-grounded
                    citations = <Map<String, dynamic>>[];
                    bullets = (direct['bullets'] is Iterable) ? (direct['bullets'] as Iterable).map((e) => e.toString()).toList() : [];
                  }
                }
              } catch (_) {}
            } else {
              // No chunks indexed for this book — try txt fallback files for that book name before direct OpenAI
              final txt = await _loadTxtFallbackForBook(bookId);
              if (txt != null && txt.isNotEmpty) {
                // show brief staged progress (visual only)
                if (mounted) {
                  setState(() => _response = 'Preparing text fallback from local TXT...');
                }
                // Prefer returning a short verbatim snippet straight from the local TXT
                // when it contains relevant keywords — this avoids unnecessary OpenAI calls
                final snippet = _extractRelevantSnippet(txt, message);
                if (snippet.isNotEmpty) {
                  answer = snippet;
                  citations = [
                    {'book': bookId, 'page': 1, 'chunk_index': 0, 'quote': snippet}
                  ];
                  bullets = [snippet.length > 120 ? snippet.substring(0, 120) + '...' : snippet];
                  if (mounted) setState(() => _response = answer);
                } else {
                    // If no short verbatim excerpt is found, pass the full TXT as a single chunk
                    // in the shape expected by RagService (each item has a 'chunk' map).
                    final singleChunk = [
                      {
                        'chunk': {
                          'book': bookId,
                          'start_page': 1,
                          'end_page': 1,
                          'text': txt
                        }
                      }
                    ];
                    // Show upload UI while we're sending the TXT fallback so user sees progress
                    if (mounted) {
                      setState(() {
                        _isUploading = true;
                        _uploadProgress = null;
                        _response = 'Uploading local book text to improve answer...';
                      });
                    }
                    try {
                      print('[Main] Sending TXT fallback to RagService for book=$bookId; txt_len=${txt.length} matched=${_matchedTxtFile}');
                      final res = await rag.answerWithOpenAI('Book: ${bookId}\nQuestion: $message', singleChunk);
                      answer = (res['answer'] ?? '').toString();
                      try {
                        final rc = res['citations'];
                        if (rc is Iterable) {
                          citations = rc.map((e) => (e as Map).cast<String, dynamic>()).toList();
                        } else {
                          citations = List<Map<String, dynamic>>.from(rag.lastCitations);
                        }
                      } catch (_) {
                        citations = List<Map<String, dynamic>>.from(rag.lastCitations);
                      }
                      try {
                        final rb = res['bullets'];
                        if (rb is Iterable) bullets = rb.map((e) => e.toString()).toList();
                        else bullets = List<String>.from(rag.lastBullets);
                      } catch (_) {
                        bullets = List<String>.from(rag.lastBullets);
                      }
                      // If RagService reported NOT FOUND, fall back to direct OpenAI
                      try {
                        if (_isNotFoundAnswer(answer) && keyToUse.isNotEmpty) {
                          final direct = await _askOpenAiDirectly(message, bookId ?? '', keyToUse);
                          final directAns = (direct['answer'] ?? '') as String? ?? '';
                          if (directAns.trim().isNotEmpty) {
                            answer = directAns;
                            citations = <Map<String, dynamic>>[];
                            bullets = (direct['bullets'] is Iterable) ? (direct['bullets'] as Iterable).map((e) => e.toString()).toList() : [];
                          }
                        }
                      } catch (_) {}

                      if (mounted) setState(() => _response = answer);
                    } catch (e) {
                      print('[Main] TXT fallback call failed: $e');
                    } finally {
                      if (mounted) setState(() {
                        _isUploading = false;
                        _uploadProgress = 1.0;
                      });
                    }
                }
              } else {
                // No chunks and no TXT fallback for this book.
                // ✅ ALWAYS provide an answer using direct OpenAI - never show generic "no info" message
                final directMap = await _askOpenAiDirectly('Book: ${bookId}\nQuestion: $message', bookId, keyToUse);
                answer = (directMap['answer'] ?? '') as String? ?? '';
                // Normalize bullets into List<String>
                final rawBul = directMap['bullets'];
                if (rawBul is String) {
                  bullets = [rawBul];
                } else if (rawBul is Iterable) {
                  bullets = rawBul.map((e) => e.toString()).toList();
                } else {
                  bullets = [];
                }
                // Normalize citations into List<Map<String,dynamic>>
                final rawCits = directMap['citations'];
                if (rawCits is Iterable) {
                  citations = rawCits.map((e) {
                    if (e is Map) return Map<String, dynamic>.from(e.cast());
                    return <String, dynamic>{};
                  }).toList();
                } else {
                  citations = <Map<String, dynamic>>[];
                }
              }
            }
          } catch (e) {
            // ✅ ALWAYS provide an answer even if retrieval failed - never show generic "no info" message
            print('[Main][AskQuestion] Retrieval failed ($e), using direct OpenAI fallback');
            final directMap = await _askOpenAiDirectly('Book: ${bookId}\nQuestion: $message', bookId, keyToUse);
            answer = (directMap['answer'] ?? '') as String? ?? '';
            final rawBul = directMap['bullets'];
            if (rawBul is String) {
              bullets = [rawBul];
            } else if (rawBul is Iterable) {
              bullets = rawBul.map((e) => e.toString()).toList();
            } else {
              bullets = [];
            }
            final rawCits = directMap['citations'];
            if (rawCits is Iterable) {
              citations = rawCits.map((e) {
                if (e is Map) return Map<String, dynamic>.from(e.cast());
                return <String, dynamic>{};
              }).toList();
            } else {
              citations = <Map<String, dynamic>>[];
            }
          }
        } else {
          // No book selected — use direct OpenAI
          final directMap = await _askOpenAiDirectly(message, '', keyToUse);
          answer = (directMap['answer'] ?? '') as String? ?? '';
          final rawBul = directMap['bullets'];
          if (rawBul is String) {
            bullets = [rawBul];
          } else if (rawBul is Iterable) {
            bullets = rawBul.map((e) => e.toString()).toList();
          } else {
            bullets = [];
          }
          final rawCits = directMap['citations'];
          if (rawCits is Iterable) {
            citations = rawCits.map((e) {
              if (e is Map) return Map<String, dynamic>.from(e.cast());
              return <String, dynamic>{};
            }).toList();
          } else {
            citations = <Map<String, dynamic>>[];
          }
        }
        if (mounted) {
          setState(() => _response = answer);
        }

        // If OpenAI indicates it has no access to the specified document,
        // attempt to send a local TXT fallback (if available) and retry once.
        try {
          final low = (answer ?? '').toString().toLowerCase();
          final noAccessDetected = low.contains("don't have access") || low.contains('do not have access') || low.contains('no access to specific documents') || low.contains('i do not have access');
          if (noAccessDetected && bookId != null) {
            final txt = await _loadTxtFallbackForBook(bookId);
            if (txt != null && txt.trim().isNotEmpty) {
              // Show upload UI (indeterminate while sending)
              if (mounted) {
                setState(() {
                  _isUploading = true;
                  _uploadProgress = null;
                  _response = 'Uploading local book text to improve answer...';
                });
              }
              try {
                // RagService expects a list of maps where each item has a 'chunk' map
                final singleChunk = [
                  {
                    'chunk': {
                      'book': bookId,
                      'start_page': 1,
                      'end_page': 1,
                      'text': txt
                    }
                  }
                ];
                if (mounted) {
                  setState(() {
                    _isUploading = true;
                    _uploadProgress = null;
                    _response = 'Uploading local book text to improve answer...';
                  });
                }
                print('[Main] Retrying with TXT fallback for book=$bookId; txt_len=${txt.length} matched=${_matchedTxtFile}');
                final retriedRes = await rag.answerWithOpenAI('Book: ${bookId}\nQuestion: $message', singleChunk);
                answer = (retriedRes['answer'] ?? '').toString();
                try {
                  final rc = retriedRes['citations'];
                  if (rc is Iterable) {
                    citations = rc.map((e) => (e as Map).cast<String, dynamic>()).toList();
                  } else {
                    citations = List<Map<String, dynamic>>.from(rag.lastCitations);
                  }
                } catch (_) {
                  citations = List<Map<String, dynamic>>.from(rag.lastCitations);
                }
                try {
                  final rb = retriedRes['bullets'];
                  if (rb is Iterable) bullets = rb.map((e) => e.toString()).toList();
                  else bullets = List<String>.from(rag.lastBullets);
                } catch (_) {
                  bullets = List<String>.from(rag.lastBullets);
                }
                if (mounted) setState(() => _response = answer);
              } catch (e) {
                // If retry fails, keep the original reply.
                print('[Main] TXT fallback retry failed: $e');
              } finally {
                if (mounted) setState(() {
                  _isUploading = false;
                  _uploadProgress = 1.0;
                });
              }
            }
          }
        } catch (_) {}
      } on TimeoutException {
        answer = 'Request timed out. Please try again.';
        if (mounted) {
          setState(() => _response = answer);
        }
      } on PlatformException catch (e) {
        answer = 'Platform error: ${e.message}';
        if (mounted) {
          setState(() => _response = answer);
        }
      } catch (e) {
        answer = 'Network or OpenAI error: $e';
        if (mounted) {
          setState(() => _response = answer);
        }
      } finally {
        if (mounted) {
          setState(() => _isLoading = false);
        }
      }
    } else {
      final offlineMsg =
          'Offline or API key missing. Chat requires an internet connection and a saved OpenAI API key in Settings.';
      if (mounted) {
        setState(() {
          _response = offlineMsg;
          _isLoading = false;
        });
      }
      answer = offlineMsg;
    }

    // Persist the online Q/A into local DB for later training/offline ingestion
    try {
      // store under a generic 'chat' book id; attempt to compute and save question embedding
      try {
        // Save the final QA under the selected book if present, otherwise under 'chat'
        final saveBook = _selectedBook ?? widget.selectedBook ?? 'chat';
        print('[Main][SaveAttempt] Q: "$combinedQuery"');
        print('[Main][SaveAttempt] A: "${_response}"');
        if (_response.trim().isNotEmpty) {
          if (keyToUse.isNotEmpty) {
            final backend = await BackendConfig.getInstance();
            final embSvc2 = EmbeddingService(backend);
            final qEmb = await embSvc2.embedText(combinedQuery);
            // Diagnostic: log embedding length and sample values
            try {
              print(
                  '[Main][Diag] Generated question embedding len=${qEmb.length} sample=${qEmb.take(6).toList()}');
            } catch (_) {}
            final id = await VectorDB.insertQaPair(
                saveBook, combinedQuery, _response, qEmb);
            print(
                '[Main] Saved chat QA locally for training (with embedding) id=$id book=$saveBook');
            // UI confirmation
            try {
              ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Saved answer locally (id=$id)')));
            } catch (_) {}
          } else {
            final id = await VectorDB.insertQaPair(
                saveBook, combinedQuery, _response, null);
            print(
                '[Main] Saved chat QA locally for training (no embedding - no API key) id=$id book=$saveBook');
            try {
              ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Saved answer locally (id=$id)')));
            } catch (_) {}
          }
        } else {
          print(
              '[Main][Skip] Not saving chat QA because answer is empty for Q: "$combinedQuery"');
        }
      } catch (e) {
        try {
          await VectorDB.insertQaPair(
              widget.selectedBook ?? 'chat', message, _response, null);
        } catch (_) {}
      }
    } catch (e) {
      print('[Main] Failed to save chat QA: $e');
    }
    // Trigger a background upload of any unsynced QA to Firebase so offline copies propagate quickly
    try {
      final sync = FirebaseSync('https://tashahit400-default-rtdb.asia-southeast1.firebasedatabase.app/');
      // fire-and-forget upload; it's okay if this fails silently
      sync.uploadUnsynced();
    } catch (e) {
      print('[Main] Background upload trigger failed: $e');
    }
    // Make sure we always return a structured result (answer + optional citations and bullets)
    final finalAnswer = answer.isNotEmpty ? answer : _response;
    return {'answer': finalAnswer, 'citations': citations, 'bullets': bullets};
  }

  // Fallback: ask OpenAI directly when there are no book excerpts to ground the answer.
    Future<Map<String, dynamic>> _askOpenAiDirectly(
      String question, String bookId, String apiKey) async {
    final body = {
      'model': 'gpt-4o-mini',
      'messages': [
        {
          'role': 'system',
          'content':
          'You are a helpful assistant. Answer the user question to the best of your ability. Note that no book excerpts are available; this answer is NOT grounded in the specified book.'
        },
        {
          'role': 'user',
          'content': 'Book: ${bookId}\nQuestion: ${question}'
        }
      ],
      'temperature': 0.0,
      'max_tokens': 500
    };
    http.Response? resp;
    String? lastErr;
    for (var i = 1; i <= 3; i++) {
      try {
        final prefs = await SharedPreferences.getInstance();
        final proxy = prefs.getString('OPENAI_PROXY_URL') ?? '';
        final appToken = prefs.getString('APP_TOKEN') ?? '';
        if (proxy.trim().isNotEmpty) {
          final uri = Uri.parse('${proxy.replaceAll(RegExp(r'\\/+$'), '')}/process');
          final proxyBody = jsonEncode({'chunks': ['Book: ${bookId}\nQuestion: ${question}'], 'model': 'gpt-4o-mini', 'max_tokens': 500, 'temperature': 0.0});
          // Log payload being sent to proxy (truncated)
          try {
            final preview = proxyBody.length > 2000 ? proxyBody.substring(0, 2000) + '...<truncated>' : proxyBody;
            print('[Main][OpenAI->Proxy] POST ${uri.toString()} headers={Content-Type: application/json, Authorization: Bearer <REDACTED>} body_preview=$preview');
          } catch (_) {}
          resp = await http.post(uri, headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $appToken'
          }, body: proxyBody).timeout(const Duration(seconds: 30));
        } else {
          final rawBody = jsonEncode(body);
          try {
            final preview = rawBody.length > 2000 ? rawBody.substring(0, 2000) + '...<truncated>' : rawBody;
            print('[Main][OpenAI] POST https://api.openai.com/v1/chat/completions headers={Content-Type: application/json, Authorization: Bearer <REDACTED>} body_preview=$preview');
          } catch (_) {}
          resp = await _client.post(Uri.parse('https://api.openai.com/v1/chat/completions'), headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $apiKey'
          }, body: rawBody).timeout(const Duration(seconds: 30));
        }
        if (resp.statusCode == 200) break;
        lastErr = resp.body;
        await Future.delayed(Duration(milliseconds: 150 * i));
      } catch (e) {
        lastErr = e.toString();
        await Future.delayed(Duration(milliseconds: 150 * i));
      }
    }
    if (resp == null) {
      print(
          '[Main][ERROR] No HTTP response from OpenAI direct call. lastErr=$lastErr');
      throw Exception('No response from OpenAI: $lastErr');
    }
    if (resp.statusCode != 200) {
      print(
          '[Main][ERROR] OpenAI direct returned status=${resp.statusCode} body=${resp.body}');
      throw Exception('OpenAI failed: ${resp.statusCode} ${resp.body}');
    }

    String content = '';
    try {
      final decoded = jsonDecode(resp.body) as Map<String, dynamic>?;
      content = decoded?['choices']?[0]?['message']?['content'] as String? ?? '';
    } catch (e) {
      print(
          '[Main][WARN] Failed to parse OpenAI response JSON: $e — falling back to raw body');
      content = resp.body;
    }

    content = content.trim();

    // If the model already returned a JSON object, try to extract structured fields
    try {
      final possible = content;
      // Attempt to locate the first JSON object in the response string by finding
      // the first '{' and attempting to jsonDecode from there. This is more
      // tolerant than a brittle regex and avoids parser errors.
      final start = possible.indexOf('{');
      if (start >= 0) {
        final jsonPart = possible.substring(start);
        try {
          final parsed = jsonDecode(jsonPart);
          if (parsed is Map<String, dynamic>) {
            final ans = (parsed['answer'] ?? parsed['text'] ?? '') as String? ?? '';
            final rawBullets = parsed['bullets'];
            List<String> bullets = [];
            if (rawBullets is List) bullets = rawBullets.map((e) => e.toString()).toList();
            final rawCits = parsed['citations'];
            List<Map<String, dynamic>> citations = [];
            if (rawCits is List) citations = rawCits.map((e) => (e as Map).cast<String, dynamic>()).toList();
            return {'answer': ans.trim(), 'bullets': bullets, 'citations': citations};
          }
        } catch (e) {
          // If jsonDecode fails, fall through to heuristics below
          print('[Main][WARN] JSON decode from substring failed: $e');
        }
      }
    } catch (e) {
      print('[Main][WARN] JSON extraction from model content failed: $e');
    }

    // Heuristic: generate up to 3 short bullets from the answer text
    List<String> bullets = [];
    try {
      // Split into sentence-like chunks. Avoid lookbehind (not supported
      // reliably) and call String.split(Pattern) to keep analyzer happy.
      final sentences = content.split(RegExp(r'[.!?]\s+'));
      for (var s in sentences) {
        final clean = s.replaceAll(RegExp(r'\s+'), ' ').trim();
        if (clean.isEmpty) continue;
        bullets.add(clean.length > 200 ? '${clean.substring(0, 197)}...' : clean);
        if (bullets.length >= 3) break;
      }
    } catch (_) {}

    if (bullets.isEmpty && content.isNotEmpty) {
      final preview = content.length > 240 ? '${content.substring(0, 237)}...' : content;
      bullets = [preview];
    }

    return {'answer': content, 'bullets': bullets, 'citations': <Map<String, dynamic>>[]};
  }

  // Load a text fallback for a book name from Documents/TxtBooks or bundled assets/txt_books
  Future<String?> _loadTxtFallbackForBook(String bookFileName) async {
    try {
      // Clear previous match
      if (mounted) setState(() => _matchedTxtFile = null);
      final base = _stripPdfExt(bookFileName);
      // First, check the database for a stored full text or TOC for this book
      try {
        final dbText = await VectorDB.getBookText(base);
        if (dbText != null && dbText.trim().isNotEmpty) {
          if (mounted) setState(() => _matchedTxtFile = 'db:$base');
          return dbText;
        }
      } catch (e) {
        print('[Main] getBookText DB lookup failed for $base: $e');
      }
      final dir = await getApplicationDocumentsDirectory();
      final txtDir = Directory('${dir.path}/TxtBooks');

      // Try exact match first (user-provided file)
      final userFile = File('${txtDir.path}/$base.txt');
      if (await userFile.exists()) {
        final name = userFile.path.split(Platform.pathSeparator).last;
        final raw = await userFile.readAsString();
        if (mounted) setState(() => _matchedTxtFile = name);
        return raw;
      }

      // If exact match fails, attempt a tolerant search in Documents/TxtBooks
      try {
        if (await txtDir.exists()) {
          final candidates = txtDir
              .listSync()
              .whereType<File>()
              .where((f) => f.path.toLowerCase().endsWith('.txt'))
              .toList();
          final normTarget = base.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
          File? best;
          for (var c in candidates) {
            final name = c.path.split(Platform.pathSeparator).last;
            final cname = name.replaceAll('.txt', '').toLowerCase();
            final norm = cname.replaceAll(RegExp(r'[^a-z0-9]'), '');
            if (norm == normTarget) {
              best = c; // exact normalized match
              break;
            }
          }
          // If not found by normalized equality, try contains
          if (best == null) {
            for (var c in candidates) {
              final name = c.path.split(Platform.pathSeparator).last;
              final cname = name.replaceAll('.txt', '').toLowerCase();
              if (cname.contains(base.toLowerCase()) || base.toLowerCase().contains(cname)) {
                best = c;
                break;
              }
            }
          }
          if (best != null) {
            try {
              final raw = await best.readAsString();
              if (raw.trim().isNotEmpty) {
                final name = best.path.split(Platform.pathSeparator).last;
                if (mounted) setState(() => _matchedTxtFile = name);
                return raw;
              }
            } catch (_) {}
          }
        }
      } catch (_) {}

      // Try bundled asset exact match
      try {
        final assetPath = 'assets/txt_books/$base.txt';
        final raw = await rootBundle.loadString(assetPath);
        if (raw.trim().isNotEmpty) {
          if (mounted) setState(() => _matchedTxtFile = assetPath.split('/').last);
          return raw;
        }
      } catch (_) {}

      // As a last resort, search bundled assets for a tolerant match (manifest scan)
      try {
        final manifestContent = await rootBundle.loadString('AssetManifest.json');
        final Map<String, dynamic> manifest = jsonDecode(manifestContent);
        final assetEntries = manifest.keys.where((k) => k.startsWith('assets/txt_books/') && k.toLowerCase().endsWith('.txt'));
        final normTarget = base.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
        String? found;
        for (var assetPath in assetEntries) {
          final fileName = assetPath.split('/').last;
          final nameNoExt = fileName.replaceAll('.txt', '').toLowerCase();
          final norm = nameNoExt.replaceAll(RegExp(r'[^a-z0-9]'), '');
          if (norm == normTarget || nameNoExt.contains(base.toLowerCase()) || base.toLowerCase().contains(nameNoExt)) {
            found = assetPath;
            break;
          }
        }
        if (found != null) {
          final raw = await rootBundle.loadString(found);
          if (raw.trim().isNotEmpty) {
            if (mounted) setState(() => _matchedTxtFile = found?.split('/').last);
            return raw;
          }
        }
      } catch (_) {}
    } catch (_) {}
    // No match found — clear any previous indicator
    if (mounted) setState(() => _matchedTxtFile = null);
    return null;
  }

  // Extract a relevant snippet from a larger text based on a query.
  // Returns an exact excerpt (verbatim) surrounding the first matching keyword.
  String _extractRelevantSnippet(String text, String query, {int before = 200, int after = 800}) {
    try {
      final norm = query.toLowerCase();
      // build candidate keywords (words longer than 3 chars)
      final terms = norm
          .replaceAll(RegExp(r'[^a-z0-9 ]'), ' ')
          .split(RegExp(r'\s+'))
          .where((s) => s.length > 3)
          .toList();
      if (terms.isEmpty) return '';

      final lowText = text.toLowerCase();
      int idx = -1;
      for (var t in terms) {
        idx = lowText.indexOf(t);
        if (idx >= 0) break;
      }
      if (idx < 0) return '';

      final start = (idx - before).clamp(0, text.length);
      final end = (idx + after).clamp(0, text.length);
      var snip = text.substring(start, end).trim();
      // Clean up line breaks for display while preserving text
      snip = snip.replaceAll(RegExp(r'\s+'), ' ');
      // If snippet is long, show a short prefix/suffix indicator
      if (start > 0) snip = '... ' + snip;
      if (end < text.length) snip = snip + ' ...';
      return snip;
    } catch (_) {
      return '';
    }
  }

  // Normalize and synthesize a concise answer and up to 3 short bullets
  // from a raw botResult which may contain long excerpts.
  Map<String, dynamic> _normalizeBotResult(Map<String, dynamic>? botResult) {
    try {
      if (botResult == null) return {'answer': '', 'bullets': <String>[], 'citations': <Map<String, dynamic>>[]};
      final rawObj = botResult['answer'] ?? botResult['text'] ?? '';
      final raw = rawObj?.toString().trim() ?? '';

      // Normalize incoming bullets if present
      List<String> bullets = [];
      final rawBul = botResult['bullets'];
      if (rawBul is Iterable && rawBul.isNotEmpty) {
        try {
          bullets = rawBul.map((e) => e?.toString() ?? '').where((s) => s.trim().isNotEmpty).map((s) => s.trim()).toList();
        } catch (_) {
          bullets = [];
        }
      }

      // If no bullets provided, synthesize up to 3 from the raw text
      if (bullets.isEmpty && raw.isNotEmpty) {
        final parts = raw.split(RegExp(r'[.!?]\s+'))
            .map((s) => s.replaceAll(RegExp(r'\s+'), ' ').trim())
            .where((s) => s.isNotEmpty)
            .toList();
        for (var p in parts) {
          var item = p;
          if (item.length > 220) item = '${item.substring(0, 217)}...';
          bullets.add(item);
          if (bullets.length >= 3) break;
        }
      }

      // If still empty, take a short preview of the raw text
      if (bullets.isEmpty && raw.isNotEmpty) {
        bullets = [raw.length > 240 ? '${raw.substring(0, 237)}...' : raw];
      }

      // Create a concise answer: prefer an explicit short answer, otherwise first bullet or first sentence
      String answer = raw;
      // If the raw appears to be a long excerpt (many words or newlines), shorten it
      final longExcerpt = raw.length > 360 || raw.contains('\n') || raw.contains('...');
      if ((raw.isEmpty) || longExcerpt) {
        if (botResult['summary'] != null) {
          answer = botResult['summary'].toString();
        } else if (bullets.isNotEmpty) {
          // prefer first bullet as a one-line answer
          answer = bullets.first;
        } else if (raw.isNotEmpty) {
          // fallback: first 200 chars
          answer = raw.length > 200 ? '${raw.substring(0, 197)}...' : raw;
        } else {
          answer = '';
        }
      }

      // Preserve citations if present and cast safely
      List<Map<String, dynamic>> citations = [];
      final rawC = botResult['citations'];
      if (rawC is Iterable) {
        try {
          citations = rawC.map((e) => (e as Map).cast<String, dynamic>()).toList();
        } catch (_) {
          citations = [];
        }
      }

      return {'answer': answer.trim(), 'bullets': bullets, 'citations': citations};
    } catch (e) {
      print('[Main][WARN] _normalizeBotResult failed: $e');
      return {'answer': botResult?['answer']?.toString() ?? '', 'bullets': <String>[], 'citations': <Map<String, dynamic>>[]};
    }
  }

  @override
  void initState() {
    super.initState();
    _selectedBook = widget.selectedBook;
    // start a fresh chat session by default
    _createNewSession();
  }

  Future<Directory> _sessionsDir() async {
    final dir = await getApplicationDocumentsDirectory();
    final sessions = Directory('${dir.path}/ChatSessions');
    if (!await sessions.exists()) await sessions.create(recursive: true);
    return sessions;
  }

  Future<void> _createNewSession() async {
    final id = DateTime.now().millisecondsSinceEpoch.toString();
    _sessionId = 'session_$id';
    setState(() {
      _messages.clear();
    });
    await _saveCurrentSession();
    await _refreshSessionsList();
  }

  Future<void> _saveCurrentSession() async {
    try {
      if (_sessionId == null) return;
      final dir = await _sessionsDir();
      final file = File('${dir.path}/${_sessionId}.json');
      final out = jsonEncode(_messages);
      await file.writeAsString(out);
    } catch (_) {}
  }

  Future<void> _refreshSessionsList() async {
    try {
      final dir = await _sessionsDir();
      final files = dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.json'))
          .toList();
      files.sort((a, b) =>
          b.statSync().modified.compareTo(a.statSync().modified));
      final List<Map<String, dynamic>> sessions = [];
      for (final f in files) {
        try {
          final name = f.path.split('\\').last;
          final ts = f.statSync().modified;
          String preview = '';
          try {
            final raw = await f.readAsString();
            final List<dynamic> parsed = jsonDecode(raw) as List<dynamic>;
            if (parsed.isNotEmpty) {
              // Show last message preview
              final last = parsed.cast<Map<String, dynamic>>().lastWhere(
                      (_) => true,
                  orElse: () => {});
              if (last != null) preview = (last['text'] ?? '').toString();
            }
          } catch (_) {}
          sessions.add({
            'id': name.replaceAll('.json', ''),
            'file': f.path,
            'modified': ts,
            'preview': preview
          });
        } catch (_) {}
      }
      _sessionsList = sessions;
      if (mounted) {
        setState(() {});
      }
    } catch (_) {}
  }

  Future<void> _loadSession(String id) async {
    try {
      final dir = await _sessionsDir();
      final file = File('${dir.path}/${id}.json');
      if (!await file.exists()) return;
      final raw = await file.readAsString();
      final List<dynamic> parsed = jsonDecode(raw) as List<dynamic>;
      setState(() {
        _sessionId = id;
        _messages.clear();
        _messages
            .addAll(parsed.map((e) => (e as Map<String, dynamic>)).toList());
      });
      await _refreshSessionsList();
    } catch (_) {}
  }

  Future<String?> _pickBookFromDocuments() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final pdfDir = Directory('${dir.path}/BooksSource');
      if (!await pdfDir.exists()) return null;
      final files = pdfDir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.toLowerCase().endsWith('.pdf'))
          .toList();
      final pick = await showBookPickerDialog(context, files,
          title: 'Select a book');
      return pick;
    } catch (_) {
      return null;
    }
  }

  String _mockChatbotResponse(String input) {
    final normalized = input.toLowerCase();
    if (normalized.contains('list') || normalized.contains('books')) {
      return 'You have ${widget.bookCount} books in your library.';
    }
    if (normalized.contains('help')) {
      return 'You can ask me to open a book, search by title, or list your books.';
    }
    if (normalized.contains('open')) {
      return 'Try tapping a book in the library to open it.';
    }
    return 'I can\'t perform that action offline. Try searching or opening a book.';
  }

  String _offlineFaqResponse(String input) {
    final s = input.toLowerCase();
    if (s.contains('malaria') ||
        s.contains('causes of malaria') ||
        s.contains('what causes malaria')) {
      return 'Malaria is caused by Plasmodium parasites, which are transmitted to people through the bites of infected female Anopheles mosquitoes. Common symptoms include fever, chills, headache, and nausea. If you suspect malaria, seek medical attention promptly for testing and treatment.';
    }
    if (s.contains('covid') || s.contains('coronavirus')) {
      return 'COVID-19 is caused by the SARS-CoV-2 virus. Common symptoms include fever, cough, and difficulty breathing. Follow local public health guidance and seek medical care if symptoms are severe.';
    }
    // Fallback to generic offline guidance
    return 'I am currently offline and cannot fetch detailed answers. Try again when you have an internet connection, or ask me to search your library for relevant documents.';
  }

  @override
  void dispose() {
    _messageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // WhatsApp-like chat UI
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: SizedBox(
        width: 720,
        height: 520,
        child: Column(
          children: [
            // Header
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(12)),
                  boxShadow: [
                    BoxShadow(
                        color: Colors.black12,
                        blurRadius: 6)
                  ]),
              child: Row(
                children: [
                  const CircleAvatar(
                      backgroundColor: Colors.green,
                      child: Icon(Icons.book, color: Colors.white)),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Chat',
                            style: TextStyle(
                                fontWeight: FontWeight.w700, fontSize: 16)),
                        if ((_selectedBook ?? widget.selectedBook) != null)
                          Text((_selectedBook ?? widget.selectedBook)!,
                              style: const TextStyle(
                                  fontSize: 12, color: Colors.black54),
                              overflow: TextOverflow.ellipsis),
                      ],
                    ),
                  ),
                  IconButton(
                      icon: const Icon(Icons.history),
                      tooltip: 'History',
                      onPressed: () async {
                        await _refreshSessionsList();
                        // show session picker with previews
                        final pick = await showDialog<String?>(
                            context: context, builder: (ctx) {
                          return Dialog(
                            child: SizedBox(
                              width: 520,
                              height: 420,
                              child: Column(
                                children: [
                                  Padding(
                                      padding: const EdgeInsets.all(12),
                                      child: Text('Chat history',
                                          style: TextStyle(
                                              fontSize: 18,
                                              fontWeight: FontWeight.w700))),
                                  Expanded(
                                    child: ListView.separated(
                                      itemCount: _sessionsList.length,
                                      separatorBuilder: (_, __) =>
                                      const Divider(height: 1),
                                      itemBuilder: (c, idx) {
                                        final s = _sessionsList[idx];
                                        return ListTile(
                                          title: Text(s['id']),
                                          subtitle: Column(
                                              crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                              children: [
                                                Text(
                                                    (s['modified'] as DateTime)
                                                        .toLocal()
                                                        .toString(),
                                                    style: const TextStyle(
                                                        fontSize: 12)),
                                                const SizedBox(height: 6),
                                                Text(
                                                    (s['preview'] ?? '')
                                                        .toString(),
                                                    maxLines: 2,
                                                    overflow:
                                                    TextOverflow.ellipsis)
                                              ]),
                                          onTap: () =>
                                              Navigator.pop(ctx, s['id'] as String),
                                        );
                                      },
                                    ),
                                  ),
                                  Row(
                                      mainAxisAlignment: MainAxisAlignment.end,
                                      children: [
                                        TextButton(
                                            onPressed: () =>
                                                Navigator.pop(ctx),
                                            child: const Text('Close'))
                                      ]),
                                ],
                              ),
                            ),
                          );
                        });
                        if (pick != null) {
                          await _loadSession(pick);
                          // scroll to bottom after loading
                          await Future.delayed(const Duration(milliseconds: 40));
                          _scrollController.jumpTo(
                              _scrollController.position.maxScrollExtent + 100);
                        }
                      }),
                  IconButton(
                      icon: const Icon(Icons.swap_horiz),
                      tooltip: 'Change book',
                      onPressed: () async {
                        final pick = await _pickBookFromDocuments();
                        if (pick != null) {
                          setState(() => _selectedBook = pick);
                        }
                      }),
                  IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.pop(context)),
                ],
              ),
            ),
            if (_isUploading)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                color: Colors.white,
                child: _uploadProgress != null
                    ? LinearProgressIndicator(value: _uploadProgress)
                    : const LinearProgressIndicator(),
              ),
            // Message area
            Expanded(
              child: Container(
                color: Colors.grey[50],
                child: ListView.builder(
                  controller: _scrollController,
                  padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
                  itemCount: _messages.isEmpty ? 1 : _messages.length,
                  itemBuilder: (ctx, i) {
                    if (_messages.isEmpty) {
                      return Center(
                          child: Text(
                              'Say hi 👋 — ask about the book or search the library',
                              style: TextStyle(color: Colors.grey[600])));
                    }
                    final m = _messages[i];
                    final isMe = m['from'] == 'user';
                    return Align(
                      alignment:
                      isMe ? Alignment.centerRight : Alignment.centerLeft,
                      child: Container(
                        margin: const EdgeInsets.symmetric(vertical: 8),
                        constraints: BoxConstraints(
                            maxWidth: MediaQuery.of(context).size.width * 0.78,
                            minHeight: isMe ? 0 : 84),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 18, vertical: 14),
                        decoration: BoxDecoration(
                          color: isMe ? Colors.green[600] : Colors.white,
                          borderRadius: BorderRadius.only(
                            topLeft: const Radius.circular(12),
                            topRight: const Radius.circular(12),
                            bottomLeft: Radius.circular(isMe ? 12 : 0),
                            bottomRight: Radius.circular(isMe ? 0 : 12),
                          ),
                          boxShadow: [
                            BoxShadow(
                                color: Colors.black12,
                                blurRadius: 4,
                                offset: const Offset(0, 2))
                          ],
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // If the model explicitly reported no relevant info in the
                            // selected book, render a friendlier suggestion UI that
                            // invites the user to broaden the search. Also render a
                            // small badge indicating whether the answer is book-grounded
                            // or a general web answer.
                            Builder(builder: (ctx) {
                              final textVal = (m['text'] ?? '').toString();
                              final noInfoExact = 'No relevant information found in the selected book.';
                              final isNoInfo = m['from'] == 'bot' && textVal.trim() == noInfoExact;
                              final grounded = (m['grounded'] as bool?) ?? false;
                              final badge = grounded ? 'Book' : 'Bot';
                              // Show animated loading circle for bot processing or indexing
                              final isProcessing = m['from'] == 'bot' && m['status'] == 'processing';
                              final isIndexing = m['from'] == 'bot' && textVal.contains('Indexing book text');
                              if (isProcessing || isIndexing) {
                                return Row(
                                  children: [
                                    const SizedBox(
                                      width: 22,
                                      height: 22,
                                      child: CircularProgressIndicator(strokeWidth: 3),
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(child: Text(textVal,
                                        style: TextStyle(
                                            color: isMe ? Colors.white : Colors.black87,
                                            fontSize: 15,
                                            fontWeight: FontWeight.w500))),
                                  ],
                                );
                              }
                              if (isNoInfo) {
                                return Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(children: [
                                      Icon(Icons.error_outline, color: Colors.orange[700]),
                                      const SizedBox(width: 8),
                                      Expanded(child: Text('No relevant information found in the selected book.', style: TextStyle(fontWeight: FontWeight.w700, color: isMe ? Colors.white : Colors.black87))),
                                    ]),
                                    const SizedBox(height: 8),
                                    Text('Try searching across all books or rephrase your question to broaden results.', style: TextStyle(color: isMe ? Colors.white70 : Colors.black54, fontSize: 13)),
                                    const SizedBox(height: 8),
                                    Row(children: [
                                      TextButton(
                                        onPressed: _searchAllBooksForLastQuery,
                                        child: const Text('Search all books'),
                                      ),
                                      const SizedBox(width: 8),
                                      TextButton(
                                        onPressed: () {
                                          // allow user to view the selected book
                                          if ((_selectedBook ?? widget.selectedBook) != null) {
                                            final b = (_selectedBook ?? widget.selectedBook)!;
                                            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Selected book: $b')));
                                          }
                                        },
                                        child: const Text('View book'),
                                      )
                                    ])
                                  ],
                                );
                              }
                              // Normal reply: render the text plus a small badge
                              return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                Row(children: [
                                  Expanded(child: Text(textVal,
                                      style: TextStyle(
                                          color: isMe ? Colors.white : Colors.black87,
                                          fontSize: isMe ? 15 : 16,
                                          height: 1.35,
                                          fontWeight: isMe ? FontWeight.w500 : FontWeight.w600))),
                                  const SizedBox(width: 8),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                    decoration: BoxDecoration(
                                        color: grounded ? Colors.green[50] : Colors.grey[200],
                                        borderRadius: BorderRadius.circular(12)),
                                    child: Text(badge, style: TextStyle(fontSize: 11, color: grounded ? Colors.green[800] : Colors.black54)),
                                  )
                                ]),
                              ]);
                            }),
                            const SizedBox(height: 6),
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(m['time'] ?? '',
                                    style: TextStyle(
                                        color: (isMe
                                            ? Colors.white70
                                            : Colors.black45),
                                        fontSize: 11)),
                                const SizedBox(width: 6),
                                // Show thumbs up/down for bot replies (when not processing)
                                if (m['from'] == 'bot' && m['status'] != 'processing') ...[
                                  IconButton(
                                    icon: Icon(Icons.thumb_up_alt_outlined,
                                        size: 18, color: Colors.green[700]),
                                    tooltip: 'Helpful',
                                    onPressed: () => _handleThumbsUp(i),
                                  ),
                                  IconButton(
                                    icon: Icon(Icons.thumb_down_alt_outlined,
                                        size: 18, color: Colors.red[700]),
                                    tooltip: 'Not helpful — improve answer',
                                    onPressed: () => _handleThumbsDown(i),
                                  ),
                                ] else if (m['from'] == 'bot' &&
                                    _isLoading &&
                                    i == _messages.length - 1)
                                  const SizedBox(
                                      width: 12,
                                      height: 12,
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2)),
                              ],
                            ),
                            // If the bot message contains bullets, render them as a short summary list
                            if (m['from'] == 'bot' && m['bullets'] != null && (m['bullets'] as List).isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(top: 6.0),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    for (final b in (m['bullets'] as List))
                                      Padding(
                                        padding: const EdgeInsets.only(bottom: 4.0),
                                        child: Text('• ${b.toString()}',
                                            style: TextStyle(
                                                color: isMe ? Colors.white70 : Colors.black87,
                                                fontSize: 13)),
                                      ),
                                  ],
                                ),
                              ),
                            // If the bot message contains citations, show a compact source line with a View button
                            if (m['from'] == 'bot' && m['citations'] != null && (m['citations'] as List).isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(top: 6.0),
                                child: Row(
                                  children: [
                                    Expanded(
                                        child: Text(
                                            'Sources: ${(m['citations'] as List).map((c) => (c['book'] ?? '')).where((s) => s != null && s.toString().isNotEmpty).toSet().join(', ')}',
                                            style: TextStyle(
                                                color: isMe ? Colors.white70 : Colors.black45,
                                                fontSize: 12),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis)),
                                    TextButton(
                                        onPressed: () {
                                          // show a dialog listing the citations with short quotes
                                          showDialog<void>(
                                              context: context,
                                              builder: (ctx) {
                                                final List cit = m['citations'] as List;
                                                return AlertDialog(
                                                  title: const Text('Source excerpts'),
                                                  content: SizedBox(
                                                    width: 560,
                                                    child: ListView.separated(
                                                      shrinkWrap: true,
                                                      itemCount: cit.length,
                                                      separatorBuilder: (_, __) => const Divider(),
                                                      itemBuilder: (c, idx) {
                                                        final item = cit[idx] as Map<String, dynamic>;
                                                        final book = item['book'] ?? 'Unknown';
                                                        final page = item['page'] ?? item['start_page'] ?? '?';
                                                        final quote = (item['quote'] ?? item['text'] ?? '').toString();
                                                        return ListTile(
                                                          title: Text('$book — pages $page'),
                                                          subtitle: Text(quote, maxLines: 6, overflow: TextOverflow.ellipsis),
                                                          onTap: () {
                                                            Navigator.pop(ctx);
                                                            // Optionally: navigate to PDF viewer/page if app supports it
                                                          },
                                                        );
                                                      },
                                                    ),
                                                  ),
                                                  actions: [
                                                    TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close'))
                                                  ],
                                                );
                                              });
                                        },
                                        child: const Text('View'))
                                  ],
                                ),
                              ),
                          ],
                        ),
                      ),
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
                              borderRadius: BorderRadius.circular(24)),
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 12)),
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
            // Show matched TXT filename (if any) under the input bar
            if (_matchedTxtFile != null)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                color: Colors.white,
                child: Align(
                  alignment: Alignment.centerRight,
                  child: Text('Using TXT: ${_matchedTxtFile!}',
                      style: TextStyle(fontSize: 12, color: Colors.black54),
                      overflow: TextOverflow.ellipsis),
                ),
              ),
          ],
        ),
      ),
    );
  }

  void _handleSend() async {
    final msg = _messageController.text.trim();
    if (msg.isEmpty) return;
    _messageController.clear();
    final now = TimeOfDay.now().format(context);
    setState(() {
      _messages.add({'from': 'user', 'text': msg, 'time': now});
    });
    await _saveCurrentSession();
    // scroll to bottom
    await Future.delayed(const Duration(milliseconds: 40));
    _scrollController.animateTo(
        _scrollController.position.maxScrollExtent + 200,
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOut);

    // Insert a processing placeholder so the user sees ChatGPT is working.
    setState(() {
      _messages.add({
        'from': 'bot',
        'text': 'Bot thinking and extracting text...',
        'time': TimeOfDay.now().format(context),
        'status': 'processing'
      });
    });
    await _saveCurrentSession();
    await Future.delayed(const Duration(milliseconds: 60));
    _scrollController.animateTo(
        _scrollController.position.maxScrollExtent + 200,
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOut);

    // --- AUTO-INDEX TXT FALLBACK IF NEEDED ---
    String? bookId = _selectedBook ?? widget.selectedBook;
    bool indexingError = false;
    String? indexingErrorMsg;
    if (bookId != null) {
      try {
        final chunkCount = await VectorDB.chunksCountForBook(bookId);
        if (chunkCount == 0) {
          // Show loading indicator for indexing
          setState(() {
            _messages.add({
              'from': 'bot',
              'text': 'Indexing book text for search...',
              'time': TimeOfDay.now().format(context),
              'status': 'processing'
            });
          });
          await _saveCurrentSession();
          await Future.delayed(const Duration(milliseconds: 60));
          _scrollController.animateTo(
              _scrollController.position.maxScrollExtent + 200,
              duration: const Duration(milliseconds: 240),
              curve: Curves.easeOut);
          // Try to load TXT fallback and index it
          final txt = await TashaUtils.loadTxtFallbackForBook(bookId);
          if (txt != null && txt.trim().isNotEmpty) {
            final key = await TashaUtils.getOpenAiKey();
            try {
              // Index in batches and show progress
              final totalWords = txt.split(RegExp(r'\s+')).length;
              final chunkSize = 1200;
              final batchSize = 10;
              final totalChunks = (totalWords / (chunkSize / 8)).ceil();
              int indexedChunks = 0;
              int lastProgressMsgIdx = -1;
              final words = txt.replaceAll(RegExp(r'\s+'), ' ').trim().split(' ');
              final chunks = <String>[];
              int i = 0;
              while (i < words.length) {
                var buf = StringBuffer();
                while (i < words.length && buf.length + words[i].length + 1 <= chunkSize) {
                  if (buf.isNotEmpty) buf.write(' ');
                  buf.write(words[i]);
                  i++;
                }
                if (buf.isEmpty && i < words.length) {
                  buf.write(words[i]);
                  i++;
                }
                chunks.add(buf.toString());
                if (1200 > 0) {
                  final overlapChars = 200;
                  var back = 0;
                  back = (overlapChars / (chunkSize / (chunks.length + 1))).ceil();
                  final stepBack = back.clamp(0, i);
                  i = (i - stepBack).clamp(0, words.length);
                }
              }
              for (var batchStart = 0; batchStart < chunks.length; batchStart += batchSize) {
                final batchEnd = (batchStart + batchSize).clamp(0, chunks.length);
                final batch = chunks.sublist(batchStart, batchEnd);
                for (var idx = 0; idx < batch.length; idx++) {
                  try {
                    final chunkText = batch[idx];
                    List<double>? emb;
                    if (key != null && key.isNotEmpty) {
                      try {
                        final backend = await BackendConfig.getInstance();
                        emb = await EmbeddingService(backend).embedText(chunkText);
                      } catch (e) {
                        emb = null;
                      }
                    }
                    await VectorDB.insertChunk(bookId, batchStart + idx + 1, batchStart + idx + 1, chunkText, emb);
                    indexedChunks++;
                  } catch (e) {
                    print('[Main] Indexing chunk failed: $e');
                  }
                }
                // Show progress every 5 batches
                if (indexedChunks ~/ batchSize > lastProgressMsgIdx) {
                  lastProgressMsgIdx = indexedChunks ~/ batchSize;
                  setState(() {
                    _messages.add({
                      'from': 'bot',
                      'text': 'Indexing progress: $indexedChunks / $totalChunks chunks...',
                      'time': TimeOfDay.now().format(context),
                      'status': 'processing'
                    });
                  });
                  await _saveCurrentSession();
                  await Future.delayed(const Duration(milliseconds: 30));
                  _scrollController.animateTo(
                      _scrollController.position.maxScrollExtent + 200,
                      duration: const Duration(milliseconds: 120),
                      curve: Curves.easeOut);
                }
                await Future.delayed(const Duration(milliseconds: 10));
              }
            } catch (e) {
              indexingError = true;
              indexingErrorMsg = 'Indexing failed: ${e.toString()}';
            }
          } else {
            indexingError = true;
            indexingErrorMsg = 'No TXT fallback found for the selected book.';
          }
          // Remove the indexing loading and progress messages
          for (var i = _messages.length - 1; i >= 0; i--) {
            final m = _messages[i];
            if (m['from'] == 'bot' && m['status'] == 'processing') {
              setState(() {
                _messages.removeAt(i);
              });
            }
          }
          // If there was an error, show it in chat
          if (indexingError && indexingErrorMsg != null) {
            setState(() {
              _messages.add({
                'from': 'bot',
                'text': indexingErrorMsg,
                'time': TimeOfDay.now().format(context),
                'status': 'error'
              });
            });
            await _saveCurrentSession();
            await Future.delayed(const Duration(milliseconds: 60));
            _scrollController.animateTo(
                _scrollController.position.maxScrollExtent + 200,
                duration: const Duration(milliseconds: 240),
                curve: Curves.easeOut);
            return;
          }
        }
      } catch (e) {
        print('[Main] Auto-index TXT fallback failed: $e');
        setState(() {
          _messages.add({
            'from': 'bot',
            'text': 'Indexing failed: ${e.toString()}',
            'time': TimeOfDay.now().format(context),
            'status': 'error'
          });
        });
        await _saveCurrentSession();
        await Future.delayed(const Duration(milliseconds: 60));
        _scrollController.animateTo(
            _scrollController.position.maxScrollExtent + 200,
            duration: const Duration(milliseconds: 240),
            curve: Curves.easeOut);
        return;
      }
    }

    final botResult = await _sendMessage(msg);

    // Normalize / synthesize a concise answer + bullets when the model returns
    // long excerpts or omits structured fields.
    final normalized = _normalizeBotResult((botResult is Map) ? (botResult as Map<String, dynamic>) : null);

    // --- PATCH CITATIONS FOR TXT FALLBACK ---
    // If citations exist, ensure page numbers reference correct chunk indices
    if (normalized['citations'] is List && bookId != null) {
      final List citations = normalized['citations'];
      for (var c in citations) {
        if (c is Map<String, dynamic>) {
          // If page is missing or '?', set to chunk_index + 1
          if ((c['page'] == null || c['page'].toString() == '?' || c['page'].toString().isEmpty) && c.containsKey('chunk_index')) {
            c['page'] = (c['chunk_index'] is int) ? (c['chunk_index'] + 1) : c['chunk_index'];
          }
        }
      }
    }

    // Replace the last processing message with the real reply (include citations if any)
    for (var i = _messages.length - 1; i >= 0; i--) {
      final m = _messages[i];
      if (m['from'] == 'bot' && m['status'] == 'processing') {
        setState(() {
          _messages[i] = {
            'from': 'bot',
            'text': normalized['answer'] ?? '',
            'time': TimeOfDay.now().format(context),
            'citations': normalized['citations'] ?? [],
            'bullets': normalized['bullets'] ?? []
          };
        });
        break;
      }
    }
    await _saveCurrentSession();
    await Future.delayed(const Duration(milliseconds: 60));
    _scrollController.animateTo(
        _scrollController.position.maxScrollExtent + 200,
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOut);
  }

  // Helper: when the bot replied that no info exists in the selected book,
  // offer to search across all books. This finds the last user message and
  // resends it with no book scope (temporarily clearing `_selectedBook`).
  Future<void> _searchAllBooksForLastQuery() async {
    try {
      String? lastUser;
      for (var i = _messages.length - 1; i >= 0; i--) {
        final m = _messages[i];
        if (m['from'] == 'user') {
          lastUser = (m['text'] ?? '').toString();
          break;
        }
      }
      if (lastUser == null || lastUser.trim().isEmpty) return;

      final prevSelected = _selectedBook;
      // Clear selected book to broaden search
      setState(() => _selectedBook = null);

      // Insert a processing placeholder
      final now = TimeOfDay.now().format(context);
      setState(() {
        _messages.add({
          'from': 'bot',
          'text': 'Searching all books...',
          'time': now,
          'status': 'processing'
        });
      });
      await _saveCurrentSession();
      await Future.delayed(const Duration(milliseconds: 60));

      final botResult = await _sendMessage(lastUser);
      final normalized = _normalizeBotResult((botResult is Map) ? (botResult as Map<String, dynamic>) : null);

      // Replace the last processing placeholder with the new result
      for (var i = _messages.length - 1; i >= 0; i--) {
        final m = _messages[i];
        if (m['from'] == 'bot' && m['status'] == 'processing') {
          setState(() {
            _messages[i] = {
              'from': 'bot',
              'text': normalized['answer'] ?? '',
              'time': TimeOfDay.now().format(context),
              'citations': normalized['citations'] ?? [],
              'bullets': normalized['bullets'] ?? []
            };
          });
          break;
        }
      }

      await _saveCurrentSession();

      // Restore previously selected book so UI state isn't unexpectedly changed
      setState(() => _selectedBook = prevSelected);
    } catch (e) {
      print('[Main] broaden search failed: $e');
    }
  }

  // User-feedback handlers: thumbs up / thumbs down on bot replies
  void _handleThumbsUp(int botMessageIndex) async {
    try {
      // For now, a thumbs-up just gives a short confirmation to the user.
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Thanks — glad this was helpful')));
      // Optionally, we could tag the QA as positively-rated in future work.
    } catch (_) {}
  }

  void _handleThumbsDown(int botMessageIndex) async {
    try {
      // Start a reinforcement/refinement attempt for the bot reply at index
      await _reinforceAnswerAt(botMessageIndex);
    } catch (e) {
      print('[Main] _handleThumbsDown failed: $e');
      try {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Failed to refine answer')));
      } catch (_) {}
    }
  }

  // Reinforce (re-answer + save) when user marks a bot reply as unhelpful.
  Future<void> _reinforceAnswerAt(int botMessageIndex) async {
    if (botMessageIndex < 0 || botMessageIndex >= _messages.length) return;
    final botMsg = _messages[botMessageIndex];
    if (botMsg['from'] != 'bot') return;

    // Find the preceding user message to use as the question
    String? userQuestion;
    for (var i = botMessageIndex - 1; i >= 0; i--) {
      final m = _messages[i];
      if (m['from'] == 'user') {
        userQuestion = (m['text'] ?? '').toString();
        break;
      }
    }
    if (userQuestion == null || userQuestion.trim().isEmpty) {
      try {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Could not find the original question')));
      } catch (_) {}
      return;
    }

    // Show an inline status for this bot message while refining
    setState(() {
      _messages[botMessageIndex] = {
        ...botMsg,
        'status': 'reinforcing',
        'text': 'Improving answer...'
      };
    });

    await _ensureCachedKey();
    final key = _cachedApiKey ?? '';
    if (key.isEmpty) {
      try {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('OpenAI API key missing — save it in Settings')));
      } catch (_) {}
      // restore previous text
      setState(() {
        _messages[botMessageIndex] = botMsg;
      });
      return;
    }

    final bookId = _selectedBook ?? widget.selectedBook;
    final backend = await BackendConfig.getInstance();
    final embSvc = EmbeddingService(backend);
    final rag = RagService(embSvc, backend);

    try {
      // Retrieve supporting chunks (scoped to the same book if possible)
      List<Map<String, dynamic>> chunks = [];
      try {
        chunks = await rag.retrieve(userQuestion, topK: 8, book: bookId);
      } catch (_) {
        chunks = [];
      }

      // Build a refinement prompt including the previous answer
      final prevAnswer = (botMsg['text'] ?? '').toString();
      final refinePrompt =
          'Book: ${bookId ?? ''}\nQuestion: $userQuestion\nPreviousAnswer: $prevAnswer\n\nInstruction: The user marked the previous answer as unhelpful. Using ONLY the provided excerpts, improve, clarify, or correct the previous answer. If the excerpts do not contain enough information, respond with exactly "No relevant information found in the selected book."';

      // Ask RagService to re-answer (it will call OpenAI)
      final refined = await rag.answerWithOpenAI(refinePrompt, chunks);
      final refinedAnswer = (refined['answer'] ?? '').toString();

      if (refinedAnswer.trim().isEmpty) {
        try {
          ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Could not refine the answer')));
        } catch (_) {}
        // restore old message
        setState(() {
          _messages[botMessageIndex] = botMsg;
        });
        return;
      }

      // Replace the bot message with the refined answer and clear status
      setState(() {
        _messages[botMessageIndex] = {
          'from': 'bot',
          'text': refinedAnswer,
          'time': TimeOfDay.now().format(context),
          'citations': refined['citations'] ?? [],
          'bullets': refined['bullets'] ?? []
        };
      });

      // Save the refined QA locally for future offline use.
      try {
        final saveBook = bookId ?? 'chat';
        final combinedQuery = (bookId != null) ? '[$bookId] $userQuestion' : userQuestion;
        try {
          final qEmb = await embSvc.embedText(combinedQuery);
          await VectorDB.insertQaPair(saveBook, combinedQuery, refinedAnswer, qEmb);
        } catch (_) {
          await VectorDB.insertQaPair(saveBook, combinedQuery, refinedAnswer, null);
        }
      } catch (_) {}

      try {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Answer improved and saved')));
      } catch (_) {}
    } catch (e) {
      print('[Main] _reinforceAnswerAt error: $e');
      try {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Refinement failed')));
      } catch (_) {}
      // restore original message on failure
      setState(() {
        _messages[botMessageIndex] = botMsg;
      });
    }
  }
}

// Offline chat moved to ui/offline_chat_bot.dart

// ---------------- Placeholder Pages ----------------
class NotificationsPage extends StatelessWidget {
  const NotificationsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Notifications')),
      body: const Center(child: Text('No notifications yet')),
    );
  }
}

class UpdatesPage extends StatefulWidget {
  const UpdatesPage({super.key});

  @override
  State<UpdatesPage> createState() => _UpdatesPageState();
}

class _UpdatesPageState extends State<UpdatesPage> {
  Map<String, List<dynamic>> groups = {};
  bool loading = true;
  String? error;
  String serverDomain = '';
  // Derived list of books grouped by base filename. Each entry: {title, pdf, image, toc, txt}
  List<Map<String, dynamic>> books = [];
  // Displayed (filtered) list driven by the search box
  List<Map<String, dynamic>> _displayedBooks = [];
  late TextEditingController _searchController;
  // track downloads in progress by book title
  final Set<String> _downloading = {};

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController();
    _searchController.addListener(() {
      _applyFilter(_searchController.text);
    });
    _loadDomainAndFetch();
  }

  Future<void> _loadDomainAndFetch() async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final prefs = await SharedPreferences.getInstance();
      serverDomain = prefs.getString('SERVER_DOMAIN') ?? '';
      if (serverDomain.trim().isEmpty) {
        setState(() {
          error =
          'Server domain not set. Open Settings and add your server domain.';
          loading = false;
        });
        return;
      }
      await _fetchAssets();
    } catch (e) {
      setState(() {
        error = 'Failed to load settings: $e';
        loading = false;
      });
    }
  }

  Future<void> _fetchAssets() async {
    try {
      final base = serverDomain.trim();
      final url = base.endsWith('/') ? '${base}api/assets/' : '$base/api/assets/';
      final resp = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 10));
      if (resp.statusCode != 200) {
        setState(() {
          error = 'Server returned ${resp.statusCode}';
          loading = false;
        });
        return;
      }
      final Map<String, dynamic> data = jsonDecode(resp.body) as Map<String, dynamic>;
      final Map<String, List<dynamic>> parsed = {};
      for (final e in data.entries) {
        parsed[e.key] = (e.value as List<dynamic>);
      }

      // Build a flat list of all assets and group by base filename
      final allAssets = <Map<String, dynamic>>[];
      for (final entry in parsed.entries) {
        for (final item in entry.value) {
          if (item is Map<String, dynamic>) allAssets.add(item);
        }
      }

      final Map<String, Map<String, dynamic>> grouped = {};
      const imageExts = {'png', 'jpg', 'jpeg', 'webp'};
      for (final a in allAssets) {
        String name = (a['name'] ?? a['path'] ?? a['filename'] ?? '').toString();
        String urlStr = (a['url'] ?? a['path'] ?? a['download_url'] ?? '').toString();
        // Normalize relative media URLs by prefixing serverDomain so clients can fetch them.
        try {
          if (urlStr.isNotEmpty && !urlStr.startsWith('http') && !urlStr.startsWith('data:')) {
            // Ensure serverDomain ends without slash
            final baseUri = base.endsWith('/') ? base.substring(0, base.length - 1) : base;
            // urlStr may be like '/media/assets/images/Name with spaces.png' or 'media/assets/...'
            final p = urlStr.startsWith('/') ? urlStr : '/$urlStr';
            // Percent-encode path segments to handle spaces and special chars
            final encodedPath = p.split('/').map((s) => Uri.encodeComponent(s)).join('/');
            urlStr = '$baseUri$encodedPath';
          }
        } catch (_) {}
        if (name.isEmpty && urlStr.isEmpty) continue;
        if (name.isEmpty && urlStr.isNotEmpty) {
          // try to infer name from url
          try {
            name = Uri.parse(urlStr).pathSegments.last;
          } catch (_) {}
        }
        if (name.contains('/') || name.contains(Platform.pathSeparator)) {
          name = name.split(Platform.pathSeparator).last;
        }
        final dot = name.lastIndexOf('.');
        final ext = (dot >= 0) ? name.substring(dot + 1).toLowerCase() : '';
        final baseName = (dot >= 0) ? name.substring(0, dot) : name;

        final entryMap = grouped.putIfAbsent(baseName, () => {
          'title': baseName,
          'pdf': null,
          'image': null,
          'toc': null,
          'txt': null
        });

        if (ext == 'pdf') {
          entryMap['pdf'] = urlStr.isNotEmpty ? urlStr : entryMap['pdf'];
        } else if (imageExts.contains(ext)) {
          entryMap['image'] = urlStr.isNotEmpty ? urlStr : entryMap['image'];
        } else if (ext == 'txt') {
          if (name.toLowerCase().contains('toc')) {
            entryMap['toc'] = urlStr.isNotEmpty ? urlStr : entryMap['toc'];
          } else {
            entryMap['txt'] = urlStr.isNotEmpty ? urlStr : entryMap['txt'];
          }
        } else {
          if (name.toLowerCase().contains('toc')) {
            entryMap['toc'] = urlStr.isNotEmpty ? urlStr : entryMap['toc'];
          }
        }
      }

      final built = <Map<String, dynamic>>[];
      for (final v in grouped.values) {
        if (v['pdf'] != null && (v['pdf'] as String).isNotEmpty) built.add(v);
      }

      setState(() {
        groups = parsed;
        books = built;
        _displayedBooks = List<Map<String, dynamic>>.from(built);
        loading = false;
      });
    } catch (e) {
      setState(() {
        error = 'Failed to fetch assets: $e';
        loading = false;
      });
    }
  }

  void _applyFilter(String q) {
    final ql = q.trim().toLowerCase();
    if (ql.isEmpty) {
      setState(() => _displayedBooks = List<Map<String, dynamic>>.from(books));
      return;
    }
    final filtered = books.where((b) {
      try {
        final title = (b['title'] as String?) ?? '';
        final txt = title.toLowerCase();
        if (txt.contains(ql)) return true;
        // also search url/path fields and pdf name
        final pdf = (b['pdf'] as String?) ?? '';
        if (pdf.toLowerCase().contains(ql)) return true;
        final txtf = (b['txt'] as String?) ?? '';
        if (txtf.toLowerCase().contains(ql)) return true;
      } catch (_) {}
      return false;
    }).toList();
    setState(() => _displayedBooks = filtered);
  }

  Future<void> _downloadAndOpen(String url, String fileName) async {
    try {
      final messenger = ScaffoldMessenger.of(context);
      messenger.showSnackBar(const SnackBar(content: Text('Downloading...')));
      File file;
      if (url.startsWith('data:')) {
        // data:<mime>;base64,<data>
        final comma = url.indexOf(',');
        final meta = url.substring(5, comma);
        final b64 = url.substring(comma + 1);
        final bytes = base64Decode(b64);
        final tmp = await getTemporaryDirectory();
        file = File('${tmp.path}/$fileName');
        await file.writeAsBytes(bytes);
      } else if (url.startsWith('http')) {
        final resp = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 30));
        if (resp.statusCode != 200) {
          messenger.showSnackBar(
              SnackBar(content: Text('Download failed: ${resp.statusCode}')));
          return;
        }
        final tmp = await getTemporaryDirectory();
        file = File('${tmp.path}/$fileName');
        await file.writeAsBytes(resp.bodyBytes);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Unsupported URL scheme (gs:// or missing).')));
        return;
      }
      // Open the downloaded file using the existing PdfViewerPage
      if (!mounted) return;
      // ignore: use_build_context_synchronously
      Navigator.of(context)
          .push(MaterialPageRoute(builder: (_) => PdfViewerPage(file: file)));
    } catch (e) {
      final messenger = ScaffoldMessenger.of(context);
      messenger.showSnackBar(SnackBar(content: Text('Download/open failed: $e')));
    }
  }

  // Download a single URL (http or data:) into destFile. Returns true on success.
  Future<bool> _downloadUrlToFile(String url, File destFile) async {
    try {
      if (url.startsWith('data:')) {
        final comma = url.indexOf(',');
        if (comma < 0) return false;
        final b64 = url.substring(comma + 1);
        final bytes = base64Decode(b64);
        await destFile.create(recursive: true);
        await destFile.writeAsBytes(bytes);
        return true;
      } else if (url.startsWith('http')) {
        final resp = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 30));
        if (resp.statusCode != 200) return false;
        await destFile.create(recursive: true);
        await destFile.writeAsBytes(resp.bodyBytes);
        return true;
      }
      return false;
    } catch (e) {
      return false;
    }
  }

  // Download all four companion files for a book into app documents under tasha/assets/... directories.
  // book map keys: 'title','pdf','image','toc','txt'
  Future<void> _downloadAllForBook(Map<String, dynamic> book) async {
    final title = (book['title'] as String?) ?? 'book';
    if (_downloading.contains(title)) return;
    final pdfUrl = (book['pdf'] as String?) ?? '';
    final imgUrl = (book['image'] as String?) ?? '';
    final tocUrl = (book['toc'] as String?) ?? '';
    final txtUrl = (book['txt'] as String?) ?? '';
    // Require PDF, image and TXT. TOC is optional.
    if (pdfUrl.isEmpty || imgUrl.isEmpty || txtUrl.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text(
              'PDF, image and text (.txt) files are required to download. TOC is optional.')));
      return;
    }

    setState(() => _downloading.add(title));
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(const SnackBar(content: Text('Downloading files...')));

    try {
      // Store downloaded files in application documents so the Library can find them
      final dir = await getApplicationDocumentsDirectory();
      // PDFs belong in Documents/BooksSource (Library loads from here)
      final booksDir = Directory('${dir.path}/BooksSource');
      // Save cover images beside PDFs as <base>.png in the BooksSource folder
      final imagesDir = booksDir;
      // TOC file expected under Documents/table_of_contents
      final tocDir = Directory('${dir.path}/table_of_contents');
      // GPT/text files used for chat/QA live under Documents/TxtBooks (matches loader)
      final txtDir = Directory('${dir.path}/TxtBooks');
      await booksDir.create(recursive: true);
      // imagesDir is same as booksDir so no separate create needed
      await tocDir.create(recursive: true);
      await txtDir.create(recursive: true);

      // Helper to derive filename from URL
      String _filenameFromUrl(String url) {
        try {
          final p = Uri.parse(url).pathSegments;
          if (p.isNotEmpty) return Uri.decodeComponent(p.last);
        } catch (_) {}
        return title.replaceAll(RegExp(r'[^a-zA-Z0-9_.-]'), '_');
      }

      final pdfName = _filenameFromUrl(pdfUrl);
      final imgName = _filenameFromUrl(imgUrl);
      final tocName = _filenameFromUrl(tocUrl);
      final txtName = _filenameFromUrl(txtUrl);

      // Derive a canonical base name from the PDF so companion files can be
      // stored with the same base (case-insensitive, platform-safe).
      final pdfBase = _stripPdfExt(pdfName);

      final pdfFile = File('${booksDir.path}/$pdfName');
      final imgFile = File('${imagesDir.path}/$imgName');
      // Always write the TOC destination as <pdfBase>.txt in the tocDir so
      // the app's TOC loader (which prefers Documents/table_of_contents/<base>.txt)
      // can find it. If an explicit tocUrl exists, we'll download it here; if
      // only a generic txt is provided, we'll download that into both TxtBooks
      // and into table_of_contents as the TOC.
      final desiredTocFile = File('${tocDir.path}/$pdfBase.txt');
      final tocFile = (tocUrl.isNotEmpty) ? desiredTocFile : desiredTocFile;
      final txtFile = File('${txtDir.path}/$txtName');

      // Download each; if any fails, delete partials and show error
      final okPdf = await _downloadUrlToFile(pdfUrl, pdfFile);
      if (!okPdf) throw Exception('Failed to download PDF');
      final okImg = await _downloadUrlToFile(imgUrl, imgFile);
      if (!okImg) throw Exception('Failed to download image');
      // TOC is optional: if a separate tocUrl is provided, download it into
      // Documents/table_of_contents/<pdfBase>.txt. If no explicit tocUrl but a
      // txtUrl is provided, treat that txt as the TOC by saving a copy into
      // the same location so the UI will pick it up.
      if (tocUrl.isNotEmpty) {
        final okToc = await _downloadUrlToFile(tocUrl, tocFile);
        if (!okToc) throw Exception('Failed to download TOC');
      } else if (txtUrl.isNotEmpty) {
        // Download the generic txt into TxtBooks for chat/text usage, and also
        // into table_of_contents as the canonical TOC file named after the PDF.
        final okTxt = await _downloadUrlToFile(txtUrl, txtFile);
        if (!okTxt) throw Exception('Failed to download TXT');
        // Also copy/download into desiredTocFile if not already present
        try {
          // If the txtFile exists, copy its contents into desiredTocFile
          if (await txtFile.exists()) {
            final content = await txtFile.readAsBytes();
            await desiredTocFile.create(recursive: true);
            await desiredTocFile.writeAsBytes(content);
          }
        } catch (_) {}
      } else {
        // No tocUrl and no txtUrl: nothing to do for TOC
      }

      // Additionally: store downloaded TXT/TOC and cover image into DB so chat can use DB-first lookup
      try {
        String? storedText;
        if (await txtFile.exists()) {
          try {
            storedText = await txtFile.readAsString();
          } catch (_) {}
        }
        if (await desiredTocFile.exists() && (storedText == null || storedText.trim().isEmpty)) {
          try {
            storedText = await desiredTocFile.readAsString();
          } catch (_) {}
        }
        Uint8List? coverBytes;
        try {
          if (await imgFile.exists()) coverBytes = await imgFile.readAsBytes();
        } catch (_) {}
        if (storedText != null && storedText.trim().isNotEmpty) {
          try {
            await VectorDB.upsertBook(pdfBase, toc: (await desiredTocFile.exists()) ? await desiredTocFile.readAsString() : null, fullText: storedText, coverBytes: coverBytes, coverPath: imgFile.path);
            print('[Main] Saved book metadata into DB for $pdfBase');
          } catch (e) {
            print('[Main] Failed to upsertBook for $pdfBase: $e');
          }
        }
      } catch (_) {}

      messenger.showSnackBar(
          const SnackBar(content: Text('All files downloaded to app storage')));
      // Refresh library view so newly downloaded PDF appears. HomePage owns _loadBooks(), so call it via ancestor state.
      try {
        final homeState = context.findAncestorStateOfType<_HomePageState>();
        if (homeState != null) await homeState._loadBooks();
      } catch (_) {}
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Download failed: $e')));
    } finally {
      setState(() => _downloading.remove(title));
    }
  }

  bool bookContainsAll(Map<String, dynamic> book) {
    // TOC is optional. Require PDF, image, and txt (text file). If toc exists, we'll download it too.
    final pdfUrl = (book['pdf'] as String?) ?? '';
    final imgUrl = (book['image'] as String?) ?? '';
    final txtUrl = (book['txt'] as String?) ?? '';
    return pdfUrl.isNotEmpty && imgUrl.isNotEmpty && txtUrl.isNotEmpty;
  }

  List<String> bookMissingList(Map<String, dynamic> book) {
    // Only consider PDF, image and txt as required. toc is optional but we will indicate if missing.
    final miss = <String>[];
    if (((book['pdf'] as String?) ?? '').isEmpty) miss.add('pdf');
    if (((book['image'] as String?) ?? '').isEmpty) miss.add('image');
    if (((book['txt'] as String?) ?? '').isEmpty) miss.add('txt');
    // For informational purposes, show toc as optional when missing by appending '(toc optional)'
    if (((book['toc'] as String?) ?? '').isEmpty) {
      // Not required — we'll show it in the UI as optional but not include it in the missing list
    }
    return miss;
  }

  Widget _smallPresenceIcon(bool present, IconData icon, String tooltip) {
    return Row(children: [
      Icon(icon,
          size: 16, color: present ? Colors.green[700] : Colors.grey[400]),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        title: SizedBox(
          height: 40,
          child: TextField(
            controller: _searchController,
            decoration: InputDecoration(
              hintText: 'Search documents...'
              ,
              prefixIcon: const Icon(Icons.search),
              filled: true,
              fillColor: Colors.white,
              contentPadding: const EdgeInsets.symmetric(vertical: 0),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide.none,
              ),
            ),
            onChanged: (v) => _applyFilter(v),
          ),
        ),
      ),
      body: Padding(
        padding: const EdgeInsets.all(12.0),
        child: loading
            ? const Center(child: CircularProgressIndicator())
            : (error != null
            ? Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(error!, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            ElevatedButton(
                onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => const SettingsPage())),
                child: const Text('Open Settings')),
          ]),
        )
            : RefreshIndicator(
          onRefresh: _fetchAssets,
          child: books.isEmpty
              ? ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: const [
                SizedBox(height: 120),
                Center(
                    child: Text('No books found on server',
                        style: TextStyle(color: Colors.grey))),
                SizedBox(height: 120)
              ])
              : ListView.separated(
            padding: const EdgeInsets.only(top: 8, bottom: 16),
            itemCount: _displayedBooks.length,
            separatorBuilder: (_, __) => const SizedBox(height: 10),
            itemBuilder: (ctx, i) {
              final b = _displayedBooks[i];
              final title = (b['title'] as String?) ?? 'Book';
              final image = (b['image'] as String?) ?? '';
              final pdfUrl = (b['pdf'] as String?) ?? '';
              // Custom card layout: fixed-size cover, wrapping title, compact metadata, fixed-width download button
              final missing = bookMissingList(b);
              final hasAll = bookContainsAll(b);
              final isBusy = _downloading.contains(title);
              return Card(
                margin: const EdgeInsets.symmetric(horizontal: 4),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
                child: InkWell(
                  onTap: pdfUrl.isNotEmpty
                      ? () => _downloadAndOpen(pdfUrl, '$title.pdf')
                      : null,
                  borderRadius: BorderRadius.circular(10),
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Cover image fixed size
                        ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: SizedBox(
                            width: 72,
                            height: 96,
                            child: image.isNotEmpty
                                ? Image.network(
                                    image,
                                    fit: BoxFit.cover,
                                    errorBuilder: (_, __, ___) => Container(
                                        color: Colors.grey[200],
                                        child: const Icon(Icons.menu_book_rounded, color: Colors.grey)),
                                  )
                                : Container(
                                    color: Colors.grey[200],
                                    child: const Icon(Icons.menu_book_rounded, color: Colors.grey)),
                          ),
                        ),
                        const SizedBox(width: 12),
                        // Title + metadata with Download button placed beneath icons
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                title,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontWeight: FontWeight.w700),
                              ),
                              const SizedBox(height: 8),
                              Row(
                                children: [
                                  _smallPresenceIcon(
                                      hasAll || (pdfUrl.isNotEmpty),
                                      Icons.picture_as_pdf,
                                      'pdf'),
                                  const SizedBox(width: 8),
                                  _smallPresenceIcon(
                                      (b['image'] as String?)?.isNotEmpty ?? false,
                                      Icons.image,
                                      'image'),
                                  const SizedBox(width: 8),
                                  _smallPresenceIcon(
                                      (b['toc'] as String?)?.isNotEmpty ?? false,
                                      Icons.list_alt,
                                      'toc'),
                                  const SizedBox(width: 8),
                                  _smallPresenceIcon(
                                      (b['txt'] as String?)?.isNotEmpty ?? false,
                                      Icons.article,
                                      'txt'),
                                  const Spacer(),
                                  Flexible(
                                    child: Text(
                                      missing.isEmpty ? 'All companion files' : 'Missing: ${missing.join(', ')}',
                                      style: TextStyle(
                                          color: missing.isEmpty ? Colors.green[700] : Colors.red[700],
                                          fontSize: 12),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              // Download button under icons (spans remaining width)
                              SizedBox(
                                width: double.infinity,
                                child: OutlinedButton.icon(
                                  onPressed: hasAll && !isBusy ? () => _downloadAllForBook(b) : null,
                                  icon: isBusy
                                      ? const SizedBox(
                                          width: 14,
                                          height: 14,
                                          child: CircularProgressIndicator(strokeWidth: 2))
                                      : const Icon(Icons.download, size: 16),
                                  label: const Text('Download'),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        )),
      ),
    );
  }
}

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.help_outline),
            tooltip: 'Help',
            onPressed: () => showAboutDialog(
                context: context,
                applicationName: 'E-Book Library',
                applicationVersion: '1.0'),
          )
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: ListView(
          children: [
            // Appearance card
            Card(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              elevation: 2,
              child: Padding(
                padding: const EdgeInsets.all(12.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Appearance',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        const Icon(Icons.light_mode),
                        const SizedBox(width: 10),
                        const Text('Use system theme'),
                        const Spacer(),
                        Switch(
                          value: Theme.of(context).brightness == Brightness.dark
                              ? false
                              : true,
                          onChanged: (v) async {
                            // Lightweight local preference only; full app theming requires provider/state management
                            final prefs = await SharedPreferences.getInstance();
                            await prefs.setBool('USE_LIGHT_THEME', v);
                            ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                    content: Text(
                                        'Theme preference saved — restart may be required')));
                          },
                        )
                      ],
                    ),
                    const SizedBox(height: 8),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.format_paint),
                      title: const Text('Accent color'),
                      subtitle: const Text('Pick a color from app theme (coming soon)'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Accent color picker planned'))),
                    )
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),

            // OpenAI key card
            _OpenAiKeyCard(),
            const SizedBox(height: 12),

            // Storage & Debug
            Card(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              elevation: 2,
              child: Padding(
                padding: const EdgeInsets.all(12.0),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('Storage & Debug',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 10),
                  ListTile(
                    leading: const Icon(Icons.delete_outline),
                    title: const Text('Clear cached files'),
                    subtitle: const Text('Deletes temporary rasterized images and caches'),
                    onTap: () async {
                      final confirmed = await showDialog<bool?>(
                          context: context,
                          builder: (ctx) => AlertDialog(
                            title: const Text('Clear cache?'),
                            content: const Text(
                                'This will delete temporary files created by the app (OCR temp files). This cannot be undone.'),
                            actions: [
                              TextButton(
                                  onPressed: () => Navigator.pop(ctx, false),
                                  child: const Text('Cancel')),
                              TextButton(
                                  onPressed: () => Navigator.pop(ctx, true),
                                  child: const Text('Delete'))
                            ],
                          ));
                      if (confirmed == true) {
                        final tmp = await getTemporaryDirectory();
                        try {
                          if (await tmp.exists()) {
                            final files = tmp.listSync(recursive: true);
                            for (var f in files) {
                              try {
                                if (f is File) await f.delete();
                              } catch (_) {}
                            }
                          }
                          ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('Cache cleared')));
                        } catch (e) {
                          ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text('Failed to clear cache: $e')));
                        }
                      }
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.storage),
                    title: const Text('Dump DB (debug)'),
                    subtitle: const Text('Print database contents to debug console'),
                    onTap: () async {
                      final messenger = ScaffoldMessenger.of(context);
                      try {
                        messenger.showSnackBar(const SnackBar(
                            content: Text('Dumping DB contents to console...')));
                        await VectorDB.dumpQaPairs();
                        await VectorDB.dumpQueryEmbeddings();
                        messenger.showSnackBar(const SnackBar(
                            content: Text('DB dump completed. Check debug console output.')));
                      } catch (e) {
                        messenger.showSnackBar(
                            SnackBar(content: Text('DB dump failed: $e')));
                      }
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.book_online_outlined),
                    title: const Text('Dump indexed chunks'),
                    subtitle: const Text('Print stored chunks (optionally for selected book) to debug console'),
                    onTap: () async {
                      final messenger = ScaffoldMessenger.of(context);
                      try {
                        messenger.showSnackBar(const SnackBar(content: Text('Dumping indexed chunks to console...')));
                        // If a book is selected in the app, dump that book's chunks; otherwise dump all chunks
                        String? selectedBook;
                        try {
                          final state = context.findAncestorStateOfType<_ChatBotDialogState>();
                          selectedBook = state?._selectedBook ?? state?.widget.selectedBook;
                        } catch (_) {}
                        if (selectedBook != null) {
                          final chunks = await VectorDB.chunksForBook(selectedBook);
                          print('[Settings] Dumping chunks for book=$selectedBook count=${chunks.length}');
                          for (var c in chunks) {
                            try {
                              final id = c['id'];
                              final text = (c['text'] ?? '').toString();
                              print('  chunk id=$id book=${c['book']} text_preview=${text.length > 240 ? text.substring(0,240) + '...' : text}');
                            } catch (_) {}
                          }
                        } else {
                          final all = await VectorDB.allChunks();
                          print('[Settings] Dumping ALL chunks count=${all.length}');
                          for (var c in all) {
                            try {
                              final id = c['id'];
                              final book = c['book'];
                              final text = (c['text'] ?? '').toString();
                              print('  chunk id=$id book=$book text_preview=${text.length > 240 ? text.substring(0,240) + '...' : text}');
                            } catch (_) {}
                          }
                        }
                        messenger.showSnackBar(const SnackBar(content: Text('Indexed chunks dumped to console')));
                      } catch (e) {
                        messenger.showSnackBar(SnackBar(content: Text('Chunk dump failed: $e')));
                      }
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.save_alt_outlined),
                    title: const Text('Index TXT fallback for selected book'),
                    subtitle: const Text('Load the .txt fallback for the selected book and index it (compute embeddings if API key saved)'),
                    onTap: () async {
                      final messenger = ScaffoldMessenger.of(context);
                      try {
                        // Find selected book from any open chat widget state
                        String? selectedBook;
                        try {
                          final state = context.findAncestorStateOfType<_ChatBotDialogState>();
                          selectedBook = state?._selectedBook ?? state?.widget.selectedBook;
                        } catch (_) {}
                        if (selectedBook == null) {
                          messenger.showSnackBar(const SnackBar(content: Text('No selected book context found. Open a book or start a chat tied to a book first.')));
                          return;
                        }

                        messenger.showSnackBar(const SnackBar(content: Text('Loading TXT fallback and indexing...')));
                        final txt = await TashaUtils.loadTxtFallbackForBook(selectedBook);
                        if (txt == null || txt.trim().isEmpty) {
                          messenger.showSnackBar(const SnackBar(content: Text('No TXT fallback found for the selected book')));
                          return;
                        }

                        final key = await TashaUtils.getOpenAiKey();
                        int inserted = 0;
                        if (key != null && key.isNotEmpty) {
                          final backend = await BackendConfig.getInstance();
                          final emb = EmbeddingService(backend);
                          inserted = await VectorDB.indexTextForBook(selectedBook, txt, embedder: emb.embedText);
                        } else {
                          // Index without embeddings (text-only chunks)
                          inserted = await VectorDB.indexTextForBook(selectedBook, txt, embedder: null);
                        }
                        messenger.showSnackBar(SnackBar(content: Text('Indexing complete — inserted $inserted chunks')));
                      } catch (e) {
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Indexing failed: $e')));
                      }
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.cleaning_services_outlined),
                    title: const Text('Clean saved "NOT FOUND" answers'),
                    subtitle: const Text('Remove or normalize previously-saved machine-readable markers'),
                    onTap: () async {
                      final confirm = await showDialog<bool?>(
                          context: context,
                          builder: (ctx) => AlertDialog(
                                title: const Text('Clean saved answers?'),
                                content: const Text(
                                    'This will remove or normalize previously-saved answers that include machine-readable "NOT FOUND" markers. This cannot be undone.'),
                                actions: [
                                  TextButton(
                                      onPressed: () => Navigator.pop(ctx, false),
                                      child: const Text('Cancel')),
                                  TextButton(
                                      onPressed: () => Navigator.pop(ctx, true),
                                      child: const Text('Run'))
                                ],
                              ));
                      if (confirm != true) return;
                      final messenger = ScaffoldMessenger.of(context);
                      try {
                        messenger.showSnackBar(const SnackBar(content: Text('Cleaning saved answers...')));
                        final updated = await VectorDB.migrateCleanNotFoundAnswers();
                        messenger.showSnackBar(SnackBar(content: Text('Clean completed — $updated rows updated/removed')));
                      } catch (e) {
                        messenger.showSnackBar(SnackBar(content: Text('Clean failed: $e')));
                      }
                    },
                  ),
                ]),
              ),
            ),

            const SizedBox(height: 12),

            // Server domain settings
            _ServerSettingsCard(),
            const SizedBox(height: 12),
            _AppTokenCard(),

            const SizedBox(height: 16),
            Center(
                child: Text('Version 1.0 • Built ${DateTime.now().year}',
                    style: const TextStyle(color: Colors.black54))),
            const SizedBox(height: 40),
          ],
        ),
      ),
      bottomNavigationBar: AppFooter(
        selectedIndex: 2,
        onDestinationSelected: (index) {
          if (index == 2) return; // already on Settings
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
        },
      ),
    );
  }
}

class _OpenAiKeyCard extends StatefulWidget {
  @override
  State<_OpenAiKeyCard> createState() => _OpenAiKeyCardState();
}

class _OpenAiKeyCardState extends State<_OpenAiKeyCard> {
  final TextEditingController _controller = TextEditingController();
  bool _obscure = true;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = prefs.getString('OPENAI_API_KEY') ?? '';
      _controller.text = key;
      setState(() {});
    } catch (_) {}
  }

  Future<void> _save() async {
    setState(() => _loading = true);
    try {
      final key = _controller.text.trim();
      if (key.isEmpty) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Please enter an API key')));
        return;
      }

      // Quick validation: call OpenAI models list to verify the key (lightweight)
      bool valid = false;
      String? validationError;
      try {
        final client = http.Client();
        final resp = await client
            .get(Uri.parse('https://api.openai.com/v1/models'), headers: {
          'Authorization': 'Bearer $key',
          'Content-Type': 'application/json'
        }).timeout(const Duration(seconds: 15));
        client.close();
        if (resp.statusCode == 200) {
          valid = true;
        } else if (resp.statusCode == 401) {
          validationError = 'Invalid API key (401). Please check your key.';
        } else {
          validationError = 'OpenAI validation returned status ${resp.statusCode}';
        }
      } catch (e) {
        validationError = 'Validation failed: $e';
      }

      final prefs = await SharedPreferences.getInstance();
      if (valid) {
        await prefs.setString('OPENAI_API_KEY', key);
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('API key saved and validated')));
      } else {
        // Do not save invalid key by default. Show detailed dialog with error and options.
        final msg = validationError ?? 'API key validation failed';
        print('[OpenAI Key Validation] Failure: $msg');

        // Provide options: Retry, Save anyway (for slow networks), or Dismiss
        final action = await showDialog<String?>(
            context: context,
            builder: (ctx) => AlertDialog(
                  title: const Text('API key validation failed'),
                  content: SingleChildScrollView(child: Text(msg)),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(ctx, 'dismiss'),
                        child: const Text('Dismiss')),
                    TextButton(
                        onPressed: () {
                          Clipboard.setData(ClipboardData(text: msg));
                          Navigator.pop(ctx, 'copied');
                          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                              content: Text('Error copied to clipboard')));
                        },
                        child: const Text('Copy')),
                    TextButton(
                        onPressed: () => Navigator.pop(ctx, 'retry'),
                        child: const Text('Retry')),
                    TextButton(
                        onPressed: () => Navigator.pop(ctx, 'save'),
                        child: const Text('Save anyway')),
                  ],
                ));

        if (action == 'save') {
          // Save the key despite validation failure (user chose to proceed)
          await prefs.setString('OPENAI_API_KEY', key);
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text('API key saved (validation failed — saved by user)')));
        } else if (action == 'retry') {
          // Retry validation once more
          setState(() => _loading = false);
          // Small delay to allow UI to update before retrying
          await Future.delayed(const Duration(milliseconds: 200));
          await _save();
          return;
        }
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to save API key: $e')));
    } finally {
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('OpenAI API Key',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          TextField(
            controller: _controller,
            decoration: InputDecoration(
              hintText: 'Paste API key here',
              suffixIcon: Row(mainAxisSize: MainAxisSize.min, children: [
                IconButton(
                    icon: Icon(_obscure ? Icons.visibility_off : Icons.visibility),
                    onPressed: () => setState(() => _obscure = !_obscure)),
                IconButton(icon: const Icon(Icons.save), onPressed: _save),
              ]),
            ),
            obscureText: _obscure,
          ),
          const SizedBox(height: 8),
            Row(children: [
            ElevatedButton.icon(
              onPressed: _loading ? null : _save,
              icon: _loading
                ? SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.save),
              label: const Text('Save')),
            const SizedBox(width: 12),
            TextButton.icon(
              onPressed: () async {
                _controller.clear();
                final prefs = await SharedPreferences.getInstance();
                await prefs.remove('OPENAI_API_KEY');
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('API key removed')));
              },
              icon: const Icon(Icons.delete_outline),
              label: const Text('Remove'))
            ])
        ]),
      ),
    );
  }
}

class _AppTokenCard extends StatefulWidget {
  @override
  State<_AppTokenCard> createState() => _AppTokenCardState();
}

class _AppTokenCardState extends State<_AppTokenCard> {
  final TextEditingController _controller = TextEditingController();
  bool _obscure = false;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // Read either legacy 'APP_TOKEN' or new 'APP_AUTH_TOKEN' for compatibility
      final key = prefs.getString('APP_AUTH_TOKEN') ?? prefs.getString('APP_TOKEN') ?? '';
      _controller.text = key;
      setState(() {});
    } catch (_) {}
  }

  Future<void> _save() async {
    setState(() => _loading = true);
    try {
      final key = _controller.text.trim();
      final prefs = await SharedPreferences.getInstance();
      // Persist under the canonical key expected by BackendConfig
      await prefs.setString('APP_AUTH_TOKEN', key);
      // Also keep legacy key for older code that may read it
      await prefs.setString('APP_TOKEN', key);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('App token saved')));
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to save token: $e')));
    } finally {
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Backend App Token', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          TextField(
            controller: _controller,
            decoration: InputDecoration(
              hintText: 'Backend app token (keeps server requests authorized)',
              suffixIcon: Row(mainAxisSize: MainAxisSize.min, children: [
                IconButton(icon: Icon(_obscure ? Icons.visibility_off : Icons.visibility), onPressed: () => setState(() => _obscure = !_obscure)),
                IconButton(icon: const Icon(Icons.save), onPressed: _save),
              ]),
            ),
            obscureText: _obscure,
          ),
          const SizedBox(height: 8),
          Row(children: [
            ElevatedButton.icon(onPressed: _loading ? null : _save, icon: _loading ? const SizedBox(width:16,height:16,child:CircularProgressIndicator(strokeWidth:2)) : const Icon(Icons.save), label: const Text('Save')),
            const SizedBox(width: 12),
            TextButton.icon(onPressed: () async { 
              _controller.clear(); 
              final prefs = await SharedPreferences.getInstance(); 
              await prefs.remove('APP_AUTH_TOKEN'); 
              await prefs.remove('APP_TOKEN'); 
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Token removed'))); 
            }, icon: const Icon(Icons.delete_outline), label: const Text('Remove'))
          ])
        ]),
      ),
    );
  }
}