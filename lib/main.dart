import 'package:epubx/epubx.dart' as epubx;
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';

/// Katalog kaydı. Okuma ilerlemesi burada değil, SharedPreferences'ta tutulur.
class Book {
  final String title;
  final String author;
  final IconData icon;
  const Book(this.title, this.author, this.icon);
}

/// SharedPreferences sarmalayıcı: WPM ve okuma ilerlemesi kalıcıdır.
class StorageService {
  static const _wpmKey = 'default_wpm';
  static const _progressPrefix = 'progress_';

  static Future<int> loadWpm({int fallback = 250}) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_wpmKey) ?? fallback;
  }

  static Future<void> saveWpm(int wpm) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_wpmKey, wpm);
  }

  static Future<void> saveProgress(String bookTitle, int percent) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('$_progressPrefix$bookTitle', percent);
  }

  static Future<Map<String, int>> loadAllProgress(List<String> titles) async {
    final prefs = await SharedPreferences.getInstance();
    return {
      for (final t in titles) t: prefs.getInt('$_progressPrefix$t') ?? 0,
    };
  }
}


/// Kullanıcıya gösterilecek Türkçe hata mesajı taşır.
class ImportException implements Exception {
  final String message;
  ImportException(this.message);
  @override
  String toString() => message;
}

class ImportResult {
  final String title;
  final String text;
  ImportResult(this.title, this.text);
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
        text = 'Dosyada metin bulunamadı.';
      }
      return ImportResult(picked.name, text);
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
    final book = await epubx.EpubReader.readBook(bytes);
    final buffer = StringBuffer();
    final chapters = book.Chapters ?? const [];
    for (final chapter in chapters) {
      buffer.writeln(_stripHtml(chapter.HtmlContent ?? ''));
    }
    return buffer.toString();
  }

  static Future<String> _extractTxt(PlatformFile file) async {
    final bytes = await _bytesOf(file);
    return String.fromCharCodes(bytes);
  }

  static String _stripHtml(String html) {
    return html
        .replaceAll(RegExp(r'<[^>]*>'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }
}

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
  final int progress;
  final VoidCallback? onTap;
  const BookTile({super.key, required this.book, required this.progress, this.onTap});

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
        title: Text(book.title, style: const TextStyle(fontWeight: FontWeight.bold)),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(book.author),
            const SizedBox(height: 6),
            LinearProgressIndicator(value: progress / 100),
            Text('%$progress'),
          ],
        ),
        trailing: const Icon(Icons.chevron_right),
      ),
    );
  }
}

class MiniBook extends StatelessWidget {
  final Book book;
  const MiniBook({super.key, required this.book});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 92,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Container(
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

/// Tüm hız seçenekleri (100-1000 WPM) herkese açıktır.
class ReaderPage extends StatefulWidget {
  final String? text;
  final String? title;

  /// İlerlemeyi kaydetmek için benzersiz anahtar (kitap adı).
  /// Alt menüdeki genel okuyucuda null'dır.
  final String? bookKey;
  const ReaderPage({super.key, this.text, this.title, this.bookKey});

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
    _loadWpm();
  }

  Future<void> _loadWpm() async {
    final saved = await StorageService.loadWpm();
    if (!mounted) return;
    setState(() {
      wpm = saved.clamp(100, 1000);
      ready = true;
    });
  }

  int get _percent => (((index + 1) / words.length) * 100).round();

  void _persistProgress() {
    final key = widget.bookKey;
    if (key == null) return;
    StorageService.saveProgress(key, _percent);
  }

  void _startTimer() {
    timer?.cancel();
    timer = Timer.periodic(Duration(milliseconds: (60000 / wpm).round()), (_) {
      if (index >= words.length - 1) {
        timer?.cancel();
        setState(() => playing = false);
        return;
      }
      setState(() => index++);
      _persistProgress();
    });
  }

  void toggle() {
    if (playing) {
      timer?.cancel();
      setState(() => playing = false);
      return;
    }
    setState(() => playing = true);
    _startTimer();
  }

  void _setWpm(int value) {
    setState(() => wpm = value);
    StorageService.saveWpm(value);
    if (playing) _startTimer(); // hız değişince oynatma anında yeni hıza geçer
  }

  void _close() {
    _persistProgress();
    Navigator.pop(context, widget.bookKey != null ? _percent : null);
  }

  @override
  void dispose() {
    timer?.cancel();
    _persistProgress();
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
                      child: Text(widget.title ?? 'FocusRead', style: const TextStyle(fontWeight: FontWeight.bold)),
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

class HomePage extends StatelessWidget {
  final List<Book> books;
  final Map<String, int> progress;
  final VoidCallback onContinue;
  const HomePage({super.key, required this.books, required this.progress, required this.onContinue});

  @override
  Widget build(BuildContext context) {
    final continuing = books.first;
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
              const Spacer(),
              IconButton(onPressed: () {}, icon: const Icon(Icons.notifications_none)),
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
            onPressed: onContinue,
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.all(17),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            ),
            child: const Text('Hemen Başla →', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
          const SizedBox(height: 28),
          const Text('Devam Edilen Kitap', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 10),
          BookTile(book: continuing, progress: progress[continuing.title] ?? 0),
          const SizedBox(height: 26),
          const Text('Popüler Kitaplar', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          SizedBox(
            height: 145,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: books.length,
              separatorBuilder: (_, __) => const SizedBox(width: 12),
              itemBuilder: (_, i) => MiniBook(book: books[i]),
            ),
          ),
        ],
      ),
    );
  }
}

class LibraryPage extends StatefulWidget {
  final List<Book> books;
  final Map<String, int> progress;
  final void Function(Book book) onOpenBook;
  final void Function(String title, String text) onImported;
  const LibraryPage({
    super.key,
    required this.books,
    required this.progress,
    required this.onOpenBook,
    required this.onImported,
  });

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  String query = '';
  bool importing = false;

  Future<void> _import() async {
    setState(() => importing = true);
    try {
      final result = await ImportService.pickAndImport();
      if (result != null) {
        widget.onImported(result.title, result.text);
      }
    } on ImportException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Beklenmeyen bir hata oluştu: $e')));
    } finally {
      if (mounted) setState(() => importing = false);
    }
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
          const SizedBox(height: 12),
          Row(
            children: [
              const Chip(label: Text('Tümü')),
              const SizedBox(width: 8),
              TextButton(
                onPressed: importing ? null : _import,
                child: importing
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('+ Dosya Yükle (PDF/EPUB/TXT)'),
              ),
            ],
          ),
          const SizedBox(height: 5),
          Expanded(
            child: ListView.separated(
              itemCount: filtered.length,
              separatorBuilder: (_, __) => const Divider(color: Colors.white10),
              itemBuilder: (_, i) => BookTile(
                book: filtered[i],
                progress: widget.progress[filtered[i].title] ?? 0,
                onTap: () => widget.onOpenBook(filtered[i]),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

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
  const ProfilePage({super.key});

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
          const ListTile(leading: Icon(Icons.menu_book), title: Text('7 Kitap'), subtitle: Text('Kütüphanendeki kitaplar')),
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
  Map<String, int> progress = {};

  final books = const [
    Book('Suç ve Ceza', 'Fyodor Dostoyevski', Icons.menu_book),
    Book('Sapiens', 'Yuval Noah Harari', Icons.auto_stories),
    Book('Düşün ve Zengin Ol', 'Napoleon Hill', Icons.book),
    Book('İnsan Ne ile Yaşar', 'Lev Tolstoy', Icons.import_contacts),
    Book('1984', 'George Orwell', Icons.library_books),
  ];

  @override
  void initState() {
    super.initState();
    _loadProgress();
  }

  Future<void> _loadProgress() async {
    final map = await StorageService.loadAllProgress(books.map((b) => b.title).toList());
    if (!mounted) return;
    setState(() {
      progress = map;
      loading = false;
    });
  }

  Future<void> _openBook(Book book) async {
    final result = await Navigator.push<int>(
      context,
      MaterialPageRoute(builder: (_) => ReaderPage(title: book.title, bookKey: book.title)),
    );
    if (result != null && mounted) {
      setState(() => progress[book.title] = result);
    }
  }

  Future<void> _openImported(String title, String text) async {
    final result = await Navigator.push<int>(
      context,
      MaterialPageRoute(builder: (_) => ReaderPage(title: title, text: text, bookKey: title)),
    );
    if (result != null && mounted) {
      setState(() => progress[title] = result);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final pages = [
      HomePage(books: books, progress: progress, onContinue: () => setState(() => index = 2)),
      LibraryPage(books: books, progress: progress, onOpenBook: _openBook, onImported: _openImported),
      const ReaderPage(),
      const StatsPage(),
      const ProfilePage(),
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
