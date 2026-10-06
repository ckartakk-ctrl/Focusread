import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive.dart' show ZipDecoder;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';

// ======================= MODEL =======================

const List<IconData> bookIcons = [
  Icons.menu_book,
  Icons.auto_stories,
  Icons.book,
  Icons.import_contacts,
  Icons.library_books,
  Icons.description,
];

class Book {
  final String id;
  String title;
  String author;
  int iconIndex;
  bool sample;
  int position; // son okunan kelimenin sırası
  int percent;
  int lastRead; // son okuma zamanı (ms)

  Book({
    required this.id,
    required this.title,
    required this.author,
    this.iconIndex = 5,
    this.sample = false,
    this.position = 0,
    this.percent = 0,
    this.lastRead = 0,
  });

  IconData get icon => bookIcons[iconIndex < 0 || iconIndex >= bookIcons.length ? 5 : iconIndex];

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'author': author,
        'icon': iconIndex,
        'sample': sample,
        'position': position,
        'percent': percent,
        'lastRead': lastRead,
      };

  factory Book.fromJson(Map<String, dynamic> j) => Book(
        id: j['id'] as String,
        title: j['title'] as String,
        author: (j['author'] as String?) ?? '',
        iconIndex: (j['icon'] as int?) ?? 5,
        sample: (j['sample'] as bool?) ?? false,
        position: (j['position'] as int?) ?? 0,
        percent: (j['percent'] as int?) ?? 0,
        lastRead: (j['lastRead'] as int?) ?? 0,
      );
}

// ======================= DEPOLAMA =======================

/// Kitap listesi SharedPreferences'ta, kitap metinleri ise uygulamanın
/// belge klasöründeki dosyalarda saklanır (büyük kitaplar için güvenli).
class LibraryStore {
  static const _key = 'library_v1';
  static const _wpmKey = 'default_wpm';

  static List<Book> seedBooks() => [
        Book(id: 'sample_1', title: 'Suç ve Ceza', author: 'Fyodor Dostoyevski', iconIndex: 0, sample: true),
        Book(id: 'sample_2', title: 'Sapiens', author: 'Yuval Noah Harari', iconIndex: 1, sample: true),
        Book(id: 'sample_3', title: 'Düşün ve Zengin Ol', author: 'Napoleon Hill', iconIndex: 2, sample: true),
        Book(id: 'sample_4', title: 'İnsan Ne ile Yaşar', author: 'Lev Tolstoy', iconIndex: 3, sample: true),
        Book(id: 'sample_5', title: '1984', author: 'George Orwell', iconIndex: 4, sample: true),
      ];

  /// İlk açılışta örnek kitaplar eklenir. Hepsi silinirse liste boş kalır
  /// (anahtar mevcut olduğu için örnekler geri gelmez).
  static Future<List<Book>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) {
      final seed = seedBooks();
      await save(seed);
      return seed;
    }
    try {
      final list = jsonDecode(raw) as List;
      return list.map((e) => Book.fromJson(e as Map<String, dynamic>)).toList();
    } catch (_) {
      return <Book>[];
    }
  }

  static Future<void> save(List<Book> books) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(books.map((b) => b.toJson()).toList()));
  }

  static Future<Directory> _dir() async {
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/books');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  static Future<void> writeText(String id, String text) async {
    final dir = await _dir();
    await File('${dir.path}/$id.txt').writeAsString(text);
  }

  static Future<String?> readText(String id) async {
    final dir = await _dir();
    final f = File('${dir.path}/$id.txt');
    if (await f.exists()) return f.readAsString();
    return null;
  }

  static Future<void> deleteText(String id) async {
    final dir = await _dir();
    final f = File('${dir.path}/$id.txt');
    if (await f.exists()) await f.delete();
  }

  static Future<int> loadWpm({int fallback = 250}) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_wpmKey) ?? fallback;
  }

  static Future<void> saveWpm(int wpm) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_wpmKey, wpm);
  }
}

// ======================= DOSYA İÇE AKTARMA =======================

class ImportException implements Exception {
  final String message;
  ImportException(this.message);
  @override
  String toString() => message;
}

class ImportResult {
  final String title;
  final String text;
  final String ext;
  ImportResult(this.title, this.text, this.ext);
}

class ImportService {
  static Future<ImportResult?> pickAndImport() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pdf', 'txt', 'epub'],
      withData: true,
    );
    if (result == null) return null;

    final picked = result.files.single;
    final extension = (picked.extension ?? '').toLowerCase();

    try {
      String text;
      switch (extension) {
        case 'pdf':
          text = await _extractPdf(picked);
          break;
        case 'epub':
          text = await _extractEpub(picked);
          break;
        case 'txt':
          text = await _extractTxt(picked);
          break;
        default:
          throw ImportException('Desteklenmeyen dosya türü: .$extension');
      }
      if (text.trim().isEmpty) {
        throw ImportException('Dosyada okunabilir metin bulunamadı.');
      }
      final title = picked.name.replaceFirst(RegExp(r'\.[^.]+$'), '');
      return ImportResult(title, text, extension);
    } on ImportException {
      rethrow;
    } catch (e) {
      throw ImportException('Dosya okunurken bir hata oluştu: $e');
    }
  }

  static Future<Uint8List> _bytesOf(PlatformFile file) async {
    if (file.bytes != null) return file.bytes!;
    if (file.path != null) return File(file.path!).readAsBytes();
    throw ImportException('Dosya verisine erişilemedi.');
  }

  static Future<String> _extractPdf(PlatformFile file) async {
    final bytes = await _bytesOf(file);
    final doc = PdfDocument(inputBytes: bytes);
    try {
      return PdfTextExtractor(doc).extractText();
    } finally {
      doc.dispose();
    }
  }

  static Future<String> _extractEpub(PlatformFile file) async {
    final bytes = await _bytesOf(file);
    final archive = ZipDecoder().decodeBytes(bytes);

    String? readText(String path) {
      final decoded = Uri.decodeFull(path);
      for (final f in archive) {
        if (f.isFile && (f.name == path || f.name == decoded)) {
          return utf8.decode(f.content as List<int>, allowMalformed: true);
        }
      }
      return null;
    }

    final container = readText('META-INF/container.xml');
    final opfPath = container == null
        ? null
        : RegExp(r'full-path="([^"]+)"').firstMatch(container)?.group(1);

    final names = <String>[];
    if (opfPath != null) {
      final opf = readText(opfPath);
      if (opf != null) {
        final baseDir = opfPath.contains('/')
            ? opfPath.substring(0, opfPath.lastIndexOf('/') + 1)
            : '';
        final manifest = <String, String>{};
        for (final m in RegExp(r'<item\b[^>]*>').allMatches(opf)) {
          final tag = m.group(0)!;
          final id = RegExp(r'\bid="([^"]+)"').firstMatch(tag)?.group(1);
          final href = RegExp(r'\bhref="([^"]+)"').firstMatch(tag)?.group(1);
          if (id != null && href != null) manifest[id] = href;
        }
        for (final m in RegExp(r'<itemref\b[^>]*>').allMatches(opf)) {
          final idref = RegExp(r'\bidref="([^"]+)"').firstMatch(m.group(0)!)?.group(1);
          final href = idref == null ? null : manifest[idref];
          if (href != null) names.add(baseDir + href);
        }
      }
    }

    if (names.isEmpty) {
      names.addAll(archive
          .where((f) => f.isFile && RegExp(r'\.(x?html?)$', caseSensitive: false).hasMatch(f.name))
          .map((f) => f.name));
      names.sort();
    }

    final buffer = StringBuffer();
    for (final n in names) {
      final html = readText(n);
      if (html != null) buffer.writeln(_stripHtml(html));
    }
    return buffer.toString();
  }

  static Future<String> _extractTxt(PlatformFile file) async {
    final bytes = await _bytesOf(file);
    return utf8.decode(bytes, allowMalformed: true);
  }

  static String _stripHtml(String html) {
    return html
        .replaceAll(RegExp(r'<(script|style)[^>]*>.*?</\1>', dotAll: true, caseSensitive: false), ' ')
        .replaceAll(RegExp(r'<[^>]*>'), ' ')
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }
}

// ======================= ORTAK WIDGET'LAR =======================

class PageFrame extends StatelessWidget {
  final Widget child;
  final String? title;
  const PageFrame({super.key, this.title, required this.child});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 18, 18, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (title != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 18),
                child: Text(title!, style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800)),
              ),
            Expanded(child: child),
          ],
        ),
      ),
    );
  }
}

class BookTile extends StatelessWidget {
  final Book book;
  final VoidCallback? onTap;
  final VoidCallback? onDelete;
  const BookTile({super.key, required this.book, this.onTap, this.onDelete});

  @override
  Widget build(BuildContext context) {
    return Card(
      color: const Color(0xFF10243A),
      child: ListTile(
        onTap: onTap,
        leading: Container(
          width: 48,
          height: 62,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(7),
            gradient: const LinearGradient(colors: [Color(0xFF8D6E63), Color(0xFF263238)]),
          ),
          child: Icon(book.icon),
        ),
        title: Text(book.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.bold)),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(book.author, maxLines: 1, overflow: TextOverflow.ellipsis),
            const SizedBox(height: 6),
            LinearProgressIndicator(value: book.percent / 100),
            Text('%${book.percent}'),
          ],
        ),
        trailing: onDelete != null
            ? IconButton(
                tooltip: 'Sil',
                icon: const Icon(Icons.delete_outline),
                onPressed: onDelete,
              )
            : const Icon(Icons.chevron_right),
      ),
    );
  }
}

class MiniBook extends StatelessWidget {
  final Book book;
  final VoidCallback? onTap;
  const MiniBook({super.key, required this.book, this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: 92,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Container(
                width: double.infinity,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(9),
                  gradient: const LinearGradient(colors: [Color(0xFF765548), Color(0xFF18212B)]),
                ),
                child: Icon(book.icon, size: 36),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              book.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
            ),
          ],
        ),
      ),
    );
  }
}

class Stat extends StatelessWidget {
  final String a, b;
  const Stat(this.a, this.b, {super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(a, style: const TextStyle(fontSize: 21, fontWeight: FontWeight.bold)),
        Text(b, style: const TextStyle(color: Colors.white54, fontSize: 12)),
      ],
    );
  }
}

class ChartPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..color = const Color(0xFF20A9FF);
    final path = Path()
      ..moveTo(0, size.height * .78)
      ..lineTo(size.width * .6, size.height * .45)
      ..lineTo(size.width * .82, size.height * .5)
      ..lineTo(size.width, size.height * .15);
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

// ======================= OKUMA SAYFASI =======================

class ReaderPage extends StatefulWidget {
  final Book? book;
  final String? text;

  /// (kelime sırası, yüzde) — okuma sırasında ve çıkışta çağrılır.
  final void Function(int position, int percent)? onProgress;
  const ReaderPage({super.key, this.book, this.text, this.onProgress});

  @override
  State<ReaderPage> createState() => _ReaderPageState();
}

class _ReaderPageState extends State<ReaderPage> {
  static const _fallbackText =
      'Bugün hava çok güzel olduğu için dışarı çıkmaya karar verdik. '
      'FocusRead ile okuma hızını geliştirebilir, dikkatini tek bir '
      'noktada toplayabilirsin.';

  int wpm = 250;
  int index = 0;
  Timer? timer;
  List<String> words = [];
  bool playing = false;
  bool ready = false;

  @override
  void initState() {
    super.initState();
    final raw = widget.text ?? _fallbackText;
    words = raw.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    if (words.isEmpty) {
      words = _fallbackText.split(RegExp(r'\s+'));
    }
    // Kaldığın yerden devam et (kitap bittiyse başa dön).
    final saved = widget.book?.position ?? 0;
    index = (saved >= words.length - 1 || saved < 0) ? 0 : saved;
    _loadWpm();
  }

  Future<void> _loadWpm() async {
    final saved = await LibraryStore.loadWpm();
    if (!mounted) return;
    setState(() {
      wpm = saved.clamp(100, 1000).toInt();
      ready = true;
    });
  }

  int get _percent => (((index + 1) / words.length) * 100).round();

  void _saveProgress() {
    if (widget.book == null) return;
    widget.onProgress?.call(index, _percent);
  }

  void _startTimer() {
    timer?.cancel();
    timer = Timer.periodic(Duration(milliseconds: (60000 / wpm).round()), (_) {
      if (index >= words.length - 1) {
        timer?.cancel();
        setState(() => playing = false);
        _saveProgress();
        return;
      }
      setState(() => index++);
      if (index % 25 == 0) _saveProgress();
    });
  }

  void toggle() {
    if (playing) {
      timer?.cancel();
      setState(() => playing = false);
      _saveProgress();
      return;
    }
    setState(() => playing = true);
    _startTimer();
  }

  void _setWpm(int value) {
    setState(() => wpm = value);
    LibraryStore.saveWpm(value);
    if (playing) _startTimer();
  }

  void _close() {
    _saveProgress();
    Navigator.pop(context);
  }

  @override
  void dispose() {
    timer?.cancel();
    _saveProgress();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!ready) {
      return const Scaffold(
        backgroundColor: Color(0xFF020B16),
        body: Center(child: CircularProgressIndicator()),
      );
    }
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _close();
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF020B16),
        body: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    IconButton(onPressed: _close, icon: const Icon(Icons.arrow_back)),
                    Expanded(
                      child: Text(
                        widget.book?.title ?? 'FocusRead',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                    Text('$_percent%'),
                  ],
                ),
              ),
              LinearProgressIndicator(value: (index + 1) / words.length, minHeight: 3),
              Expanded(
                child: Center(
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 120),
                    child: Text(
                      words[index],
                      key: ValueKey(index),
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 42, fontWeight: FontWeight.w700),
                    ),
                  ),
                ),
              ),
              Text('${index + 1} / ${words.length} kelime', style: const TextStyle(color: Colors.white54)),
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    onPressed: () => setState(() => index = index > 0 ? index - 1 : 0),
                    icon: const Icon(Icons.chevron_left, size: 32),
                  ),
                  const SizedBox(width: 15),
                  FloatingActionButton.large(
                    onPressed: toggle,
                    child: Icon(playing ? Icons.pause : Icons.play_arrow, size: 34),
                  ),
                  const SizedBox(width: 15),
                  IconButton(
                    onPressed: () => setState(() => index = index < words.length - 1 ? index + 1 : index),
                    icon: const Icon(Icons.chevron_right, size: 32),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              Text('Hız: $wpm WPM', style: const TextStyle(fontWeight: FontWeight.bold)),
              Slider(
                value: wpm.toDouble(),
                min: 100,
                max: 1000,
                divisions: 18,
                label: '$wpm WPM',
                onChanged: (v) => _setWpm(v.round()),
              ),
              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
    );
  }
}

// ======================= ANA SAYFA =======================

class HomePage extends StatelessWidget {
  final List<Book> books;
  final Book? continuing;
  final void Function(Book book) onOpen;
  final VoidCallback onStart;
  const HomePage({
    super.key,
    required this.books,
    required this.continuing,
    required this.onOpen,
    required this.onStart,
  });

  @override
  Widget build(BuildContext context) {
    final cont = continuing;
    return PageFrame(
      child: ListView(
        children: [
          Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(colors: [Color(0xFF11B5FF), Color(0xFF765CFF)]),
                ),
                child: const Icon(Icons.center_focus_strong),
              ),
              const SizedBox(width: 10),
              const Text('FocusRead', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
            ],
          ),
          const SizedBox(height: 30),
          const Text(
            'Daha hızlı oku,\ndaha fazlasını keşfet.',
            style: TextStyle(fontSize: 30, fontWeight: FontWeight.w800, height: 1.05),
          ),
          const SizedBox(height: 10),
          const Text(
            'Kitapları ve metinleri kelime kelime, odaklanarak oku.',
            style: TextStyle(color: Colors.white70, fontSize: 15),
          ),
          const SizedBox(height: 22),
          FilledButton(
            onPressed: onStart,
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.all(17),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            ),
            child: Text(
              cont != null ? 'Kaldığın Yerden Devam Et →' : 'Hemen Başla →',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
          const SizedBox(height: 28),
          if (cont != null) ...[
            const Text('Devam Edilen Kitap', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 10),
            BookTile(book: cont, onTap: () => onOpen(cont)),
            const SizedBox(height: 26),
          ],
          if (books.isNotEmpty) ...[
            const Text('Kitaplarım', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            SizedBox(
              height: 145,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: books.length,
                separatorBuilder: (_, __) => const SizedBox(width: 12),
                itemBuilder: (_, i) => MiniBook(book: books[i], onTap: () => onOpen(books[i])),
              ),
            ),
          ] else
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text(
                'Kitaplığın boş. Kitaplık sekmesinden PDF, EPUB veya TXT dosyası yükleyebilirsin.',
                style: TextStyle(color: Colors.white70),
              ),
            ),
        ],
      ),
    );
  }
}

// ======================= KİTAPLIK =======================

class LibraryPage extends StatefulWidget {
  final List<Book> books;
  final void Function(Book book) onOpenBook;
  final Future<void> Function(ImportResult result) onImported;
  final Future<void> Function(Book book) onDelete;
  final Future<void> Function() onDeleteAll;
  const LibraryPage({
    super.key,
    required this.books,
    required this.onOpenBook,
    required this.onImported,
    required this.onDelete,
    required this.onDeleteAll,
  });

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  String query = '';
  bool importing = false;

  Future<void> _import() async {
    setState(() => importing = true);
    ImportResult? result;
    try {
      result = await ImportService.pickAndImport();
    } on ImportException catch (e) {
      _snack(e.message);
    } catch (e) {
      _snack('Beklenmeyen bir hata oluştu: $e');
    }
    if (mounted) setState(() => importing = false);
    if (result != null && mounted) {
      await widget.onImported(result);
    }
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<bool> _confirm(String title, String message) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Vazgeç')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Sil')),
        ],
      ),
    );
    return ok ?? false;
  }

  Future<void> _deleteOne(Book book) async {
    final ok = await _confirm('Kitabı sil', '"${book.title}" kitaplıktan silinsin mi?');
    if (ok) await widget.onDelete(book);
  }

  Future<void> _deleteAll() async {
    final ok = await _confirm(
      'Tüm kitapları sil',
      'Örnek kitaplar dahil kitaplıktaki ${widget.books.length} kitabın hepsi ve okuma ilerlemeleri silinecek. Bu işlem geri alınamaz.',
    );
    if (ok) await widget.onDeleteAll();
  }

  @override
  Widget build(BuildContext context) {
    final filtered = widget.books.where((b) => b.title.toLowerCase().contains(query.toLowerCase())).toList();
    return PageFrame(
      title: 'Kitaplık',
      child: Column(
        children: [
          TextField(
            onChanged: (v) => setState(() => query = v),
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search),
              hintText: 'Kitap, yazar veya dosya ara...',
              filled: true,
              fillColor: const Color(0xFF10243A),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(15), borderSide: BorderSide.none),
            ),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: Wrap(
              spacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                TextButton(
                  onPressed: importing ? null : _import,
                  child: importing
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text('+ Dosya Yükle (PDF/EPUB/TXT)'),
                ),
                if (widget.books.isNotEmpty)
                  TextButton(
                    onPressed: _deleteAll,
                    style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
                    child: const Text('Tümünü Sil'),
                  ),
              ],
            ),
          ),
          Expanded(
            child: filtered.isEmpty
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        'Kitaplık boş.\n"+ Dosya Yükle" ile kitap ekleyebilirsin.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.white54),
                      ),
                    ),
                  )
                : ListView.separated(
                    itemCount: filtered.length,
                    separatorBuilder: (_, __) => const Divider(color: Colors.white10),
                    itemBuilder: (_, i) => BookTile(
                      book: filtered[i],
                      onTap: () => widget.onOpenBook(filtered[i]),
                      onDelete: () => _deleteOne(filtered[i]),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

// ======================= İSTATİSTİK / AYARLAR / PROFİL =======================

class StatsPage extends StatelessWidget {
  const StatsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return PageFrame(
      title: 'İstatistikler',
      child: ListView(
        children: [
          Container(
            padding: const EdgeInsets.all(22),
            decoration: BoxDecoration(color: const Color(0xFF0D2238), borderRadius: BorderRadius.circular(20)),
            child: const Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [Stat('280', 'WPM'), Stat('184.320', 'Kelime'), Stat('12s 36dk', 'Okuma')],
            ),
          ),
          const SizedBox(height: 24),
          const Text('Hız Gelişimi', style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold)),
          const SizedBox(height: 14),
          Container(
            height: 180,
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(color: const Color(0xFF0D2238), borderRadius: BorderRadius.circular(20)),
            child: CustomPaint(painter: ChartPainter()),
          ),
          const SizedBox(height: 24),
          const Text('Hedefler', style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          const ListTile(
            leading: Icon(Icons.flag),
            title: Text('Haftalık hedef'),
            subtitle: Text('18.420 / 50.000 kelime'),
            trailing: Text('37%'),
          ),
        ],
      ),
    );
  }
}

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: PageFrame(
        title: 'Ayarlar',
        child: ListView(
          children: [
            const Text('Okuma Ayarları', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            SwitchListTile(value: true, onChanged: (_) {}, title: const Text('Odak modu')),
            const ListTile(title: Text('Varsayılan WPM'), trailing: Text('250')),
            const ListTile(title: Text('Yazı boyutu'), trailing: Text('Orta')),
            const ListTile(title: Text('Tema'), trailing: Text('Koyu')),
            const Divider(),
            const Text('Uygulama', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            SwitchListTile(value: true, onChanged: (_) {}, title: const Text('Bildirimler')),
            const ListTile(title: Text('Dil'), trailing: Text('Türkçe')),
          ],
        ),
      ),
    );
  }
}

class ProfilePage extends StatelessWidget {
  final int bookCount;
  const ProfilePage({super.key, required this.bookCount});

  @override
  Widget build(BuildContext context) {
    return PageFrame(
      title: 'Profil',
      child: ListView(
        children: [
          const ListTile(
            leading: CircleAvatar(radius: 28, child: Icon(Icons.person)),
            title: Text('İbrahim K.'),
            subtitle: Text('Tüm özellikler açık'),
          ),
          const SizedBox(height: 20),
          ListTile(
            leading: const Icon(Icons.menu_book),
            title: Text('$bookCount Kitap'),
            subtitle: const Text('Kütüphanendeki kitaplar'),
          ),
          const ListTile(leading: Icon(Icons.history), title: Text('Okuma Geçmişi')),
          const ListTile(leading: Icon(Icons.favorite_border), title: Text('Favoriler')),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.settings),
            title: const Text('Ayarlar'),
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SettingsPage())),
          ),
        ],
      ),
    );
  }
}

// ======================= UYGULAMA =======================

void main() => runApp(const FocusReadApp());

class FocusReadApp extends StatelessWidget {
  const FocusReadApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'FocusRead',
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF06111F),
        textTheme: GoogleFonts.interTextTheme(ThemeData.dark().textTheme),
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF239BFF), brightness: Brightness.dark),
      ),
      home: const AppShell(),
    );
  }
}

class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int index = 0;
  bool loading = true;
  List<Book> books = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final loaded = await LibraryStore.load();
    if (!mounted) return;
    setState(() {
      books = loaded;
      loading = false;
    });
  }

  /// En son okunan kitap (hiç okunmadıysa listedeki ilk kitap).
  Book? _continuing() {
    Book? best;
    for (final b in books) {
      if (b.lastRead > 0 && (best == null || b.lastRead > best.lastRead)) {
        best = b;
      }
    }
    if (best != null) return best;
    return books.isNotEmpty ? books.first : null;
  }

  // Not: setState burada çağrılmaz; ReaderPage dispose olurken de çağrılabilir.
  void _onProgress(Book book, int position, int percent) {
    book.position = position;
    book.percent = percent;
    book.lastRead = DateTime.now().millisecondsSinceEpoch;
    LibraryStore.save(books);
  }

  Future<void> _openBook(Book book) async {
    final text = await LibraryStore.readText(book.id);
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ReaderPage(
          book: book,
          text: text,
          onProgress: (p, pc) => _onProgress(book, p, pc),
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  Future<void> _onImported(ImportResult r) async {
    final id = 'b_${DateTime.now().millisecondsSinceEpoch}';
    final book = Book(
      id: id,
      title: r.title,
      author: 'İçe aktarılan ${r.ext.toUpperCase()}',
      iconIndex: 5,
    );
    try {
      await LibraryStore.writeText(id, r.text);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Kitap kaydedilemedi: $e')));
      return;
    }
    setState(() => books.insert(0, book));
    await LibraryStore.save(books);
    await _openBook(book);
  }

  Future<void> _deleteBook(Book book) async {
    await LibraryStore.deleteText(book.id);
    setState(() => books.remove(book));
    await LibraryStore.save(books);
  }

  Future<void> _deleteAll() async {
    for (final b in List<Book>.from(books)) {
      await LibraryStore.deleteText(b.id);
    }
    setState(() => books.clear());
    await LibraryStore.save(books);
  }

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final pages = [
      HomePage(
        books: books,
        continuing: _continuing(),
        onOpen: _openBook,
        onStart: () {
          final b = _continuing();
          if (b != null) {
            _openBook(b);
          } else {
            setState(() => index = 2);
          }
        },
      ),
      LibraryPage(
        books: books,
        onOpenBook: _openBook,
        onImported: _onImported,
        onDelete: _deleteBook,
        onDeleteAll: _deleteAll,
      ),
      const ReaderPage(),
      const StatsPage(),
      ProfilePage(bookCount: books.length),
    ];
    return Scaffold(
      body: pages[index],
      bottomNavigationBar: NavigationBar(
        backgroundColor: const Color(0xFF08182A),
        selectedIndex: index,
        onDestinationSelected: (i) => setState(() => index = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.home_outlined), selectedIcon: Icon(Icons.home), label: 'Ana Sayfa'),
          NavigationDestination(icon: Icon(Icons.library_books_outlined), selectedIcon: Icon(Icons.library_books), label: 'Kitaplık'),
          NavigationDestination(icon: Icon(Icons.speed_outlined), selectedIcon: Icon(Icons.speed), label: 'Oku'),
          NavigationDestination(icon: Icon(Icons.insights_outlined), selectedIcon: Icon(Icons.insights), label: 'İstatistik'),
          NavigationDestination(icon: Icon(Icons.person_outline), selectedIcon: Icon(Icons.person), label: 'Profil'),
        ],
      ),
    );
  }

}
