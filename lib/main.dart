import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:archive/archive_io.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_cropper/image_cropper.dart';
import 'package:image_picker/image_picker.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

// ───────────────────────── Globals & helpers ─────────────────────────

final navKey = GlobalKey<NavigatorState>();
const native = MethodChannel('filevault/native');

const palette = <int>[
  0xFF4F7CFF, 0xFF43A047, 0xFFE53935, 0xFFFB8C00,
  0xFF8E5BD6, 0xFF14A3B8, 0xFFD81B60, 0xFF6D4C41,
  0xFF8A8A8A, 0xFFF2B705,
  0xFF1E88E5, 0xFF8BC34A, 0xFFFF7043, 0xFFEC407A,
  0xFF5E35B1, 0xFF3949AB, 0xFF00897B, 0xFF26C6DA,
  0xFF546E7A, 0xFF212121,
];

String safeName(String n) {
  var s = n.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
  if (s.isEmpty) s = 'file';
  return s;
}

bool isImage(String name) {
  const ext = ['.jpg', '.jpeg', '.png', '.gif', '.webp', '.bmp'];
  return ext.contains(p.extension(name).toLowerCase());
}

String stampNow() {
  final t = DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}-${two(t.minute)}-${two(t.second)}';
}

bool isDarkCtx(BuildContext c) => Theme.of(c).brightness == Brightness.dark;
Color pageBgOf(BuildContext c) => isDarkCtx(c) ? const Color(0xFF161B28) : const Color(0xFFDDE4EE);
Color cardOf(BuildContext c) => isDarkCtx(c) ? const Color(0xFF222A3D) : Colors.white;
Color lineOf(BuildContext c) => isDarkCtx(c) ? const Color(0xFF323D57) : const Color(0xFFC3CDE0);

String fmtSize(int b) {
  if (b < 1024) return '$b B';
  if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
  if (b < 1024 * 1024 * 1024) return '${(b / 1024 / 1024).toStringAsFixed(1)} MB';
  return '${(b / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
}

IconData fileIcon(String name) {
  switch (p.extension(name).toLowerCase()) {
    case '.jpg': case '.jpeg': case '.png': case '.gif': case '.webp': case '.heic': case '.bmp':
      return Icons.image;
    case '.mp4': case '.mkv': case '.mov': case '.avi': case '.webm': case '.3gp':
      return Icons.movie;
    case '.mp3': case '.wav': case '.m4a': case '.aac': case '.ogg': case '.flac':
      return Icons.audiotrack;
    case '.pdf':
      return Icons.picture_as_pdf;
    case '.doc': case '.docx': case '.odt': case '.txt': case '.rtf':
      return Icons.description;
    case '.xls': case '.xlsx': case '.csv':
      return Icons.table_chart;
    case '.ppt': case '.pptx':
      return Icons.slideshow;
    case '.zip': case '.rar': case '.7z':
      return Icons.folder_zip;
    default:
      return Icons.insert_drive_file;
  }
}

void toast(BuildContext c, String m) => ScaffoldMessenger.of(c)
  ..hideCurrentSnackBar()
  ..showSnackBar(SnackBar(
      content: Text(m),
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 2)));

OverlayEntry? _backEntry;
Timer? _backTimer;

void showPressAgain() {
  final overlay = navKey.currentState?.overlay;
  if (overlay == null) return;
  _backTimer?.cancel();
  _backEntry?.remove();
  final entry = OverlayEntry(
    builder: (ctx) => Positioned(
      left: 0,
      right: 0,
      bottom: MediaQuery.of(ctx).viewPadding.bottom + 6,
      child: IgnorePointer(
        child: Center(
          child: TweenAnimationBuilder<double>(
            tween: Tween<double>(begin: 0, end: 1),
            duration: const Duration(milliseconds: 150),
            builder: (c, v, child) => Opacity(opacity: v, child: child),
            child: Material(
              type: MaterialType.transparency,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
                decoration: BoxDecoration(
                  color: const Color(0xDD202124),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: const Text('Press Again',
                    style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w500)),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  _backEntry = entry;
  overlay.insert(entry);
  _backTimer = Timer(const Duration(seconds: 2), () {
    entry.remove();
    if (identical(_backEntry, entry)) _backEntry = null;
  });
}

// ───────────────────────── Model ─────────────────────────

class Item {
  String id;
  String type; // 'button' | 'note' | 'file'
  String name; // may be empty for notes
  int color;
  int opacity; // notes only: 0..100
  String? parentId;
  String? text; // note content
  String? stored; // files: "<id>/<filename>" inside the app folder
  int size;
  int order;
  int created;
  bool expanded; // notes / images: dropdown preview open

  Item({
    required this.id,
    required this.type,
    required this.name,
    required this.color,
    this.opacity = 40,
    this.parentId,
    this.text,
    this.stored,
    this.size = 0,
    required this.order,
    required this.created,
    this.expanded = false,
  });

  Map<String, dynamic> toJson() => {
        'id': id, 'type': type, 'name': name, 'color': color,
        'opacity': opacity, 'parentId': parentId, 'text': text,
        'stored': stored, 'size': size, 'order': order, 'created': created,
        'expanded': expanded, 'fv': 2,
      };

  factory Item.fromJson(Map<String, dynamic> j) => Item(
        id: j['id'], type: j['type'], name: j['name'] ?? '', color: j['color'],
        opacity: (j['type'] == 'file' && j['fv'] != 2) ? 0 : (j['opacity'] ?? 40), parentId: j['parentId'], text: j['text'],
        stored: j['stored'], size: j['size'] ?? 0,
        order: j['order'] ?? j['created'] ?? 0, created: j['created'] ?? 0,
        expanded: j['expanded'] ?? false,
      );
}

String itemLabel(Item i) {
  if (i.name.trim().isNotEmpty) return i.name.trim();
  final t = (i.text ?? '').trim();
  if (t.isEmpty) return 'this item';
  return t.length > 24 ? '${t.substring(0, 24)}…' : t;
}

// ───────────────────────── Store ─────────────────────────

class Store extends ChangeNotifier {
  late Directory root, filesDir;
  late File dataFile;
  List<Item> items = [];

  Future<void> init() async {
    // App-private, permanent storage (NOT cache).
    root = await getApplicationDocumentsDirectory();
    filesDir = Directory(p.join(root.path, 'vault_files'));
    await filesDir.create(recursive: true);
    dataFile = File(p.join(root.path, 'vault_data.json'));
    await load();
  }

  Future<void> load() async {
    items = [];
    if (await dataFile.exists()) {
      final l = jsonDecode(await dataFile.readAsString()) as List;
      items = l.map((e) => Item.fromJson(e as Map<String, dynamic>)).toList();
    }
    // Migrate files from the older flat layout ("<id>.ext") to "<id>/<name>".
    var changed = false;
    for (final it in items) {
      if (it.type == 'file' && it.stored != null && !it.stored!.contains('/')) {
        final old = File(p.join(filesDir.path, it.stored!));
        if (await old.exists()) {
          var nn = safeName(it.name);
          if (p.extension(nn).isEmpty) nn += p.extension(it.stored!);
          final dir = Directory(p.join(filesDir.path, it.id));
          await dir.create(recursive: true);
          await old.rename(p.join(dir.path, nn));
          it.stored = '${it.id}/$nn';
          it.name = nn;
          changed = true;
        }
      }
    }
    if (changed) {
      await dataFile.writeAsString(jsonEncode(items.map((e) => e.toJson()).toList()));
    }
    notifyListeners();
  }

  Future<void> save() async {
    await dataFile.writeAsString(jsonEncode(items.map((e) => e.toJson()).toList()));
    notifyListeners();
  }

  String filePath(Item i) => p.join(filesDir.path, i.stored!);

  List<Item> childrenOf(String? parent) =>
      items.where((e) => e.parentId == parent).toList()
        ..sort((a, b) {
          final c = a.order.compareTo(b.order);
          return c != 0 ? c : a.created.compareTo(b.created);
        });

  String newId() => DateTime.now().microsecondsSinceEpoch.toString();
  int nextOrder() => DateTime.now().microsecondsSinceEpoch;

  Future<void> delete(Item item) async {
    final ids = <String>{};
    void walk(String id) {
      ids.add(id);
      for (final c in items.where((e) => e.parentId == id)) {
        walk(c.id);
      }
    }

    walk(item.id);
    for (final e in items.where((e) => ids.contains(e.id) && e.type == 'file')) {
      try {
        await Directory(p.join(filesDir.path, p.dirname(e.stored!))).delete(recursive: true);
      } catch (_) {}
    }
    items.removeWhere((e) => ids.contains(e.id));
    await save();
  }

  // Adds the contents of an extracted backup BELOW what is already in the app.
  // Existing items are never touched. Every restored item gets a fresh id so it
  // can't collide with (or overwrite) anything that is already here.
  Future<int> mergeBackup(Directory tmp, void Function(double) onProgress) async {
    final raw = jsonDecode(await File(p.join(tmp.path, 'data.json')).readAsString()) as List;
    final incoming =
        raw.map((e) => Item.fromJson(Map<String, dynamic>.from(e as Map))).toList();
    incoming.sort((a, b) {
      final c = a.order.compareTo(b.order);
      return c != 0 ? c : a.created.compareTo(b.created);
    });

    var base = 0;
    for (final e in items) {
      if (e.order > base) base = e.order;
    }
    base += 1;

    final stamp = newId();
    final idMap = <String, String>{};
    var seq = 0;
    for (final o in incoming) {
      idMap[o.id] = '${stamp}r${seq++}';
    }

    final added = <Item>[];
    var i = 0;
    for (final o in incoming) {
      i++;
      final nid = idMap[o.id]!;
      String? stored;
      var name = o.name;
      if (o.type == 'file') {
        final rel = o.stored;
        if (rel == null || rel.contains('..')) continue;
        final src = File(p.join(tmp.path, 'files', rel));
        if (!await src.exists()) continue;
        var fname = p.basename(rel);
        if (!rel.contains('/')) {
          // very old backup layout: "<id>.ext"
          fname = safeName(o.name);
          if (p.extension(fname).isEmpty) fname += p.extension(rel);
          name = fname;
        }
        final dir = Directory(p.join(filesDir.path, nid));
        await dir.create(recursive: true);
        final dest = p.join(dir.path, fname);
        try {
          await src.rename(dest);
        } catch (_) {
          await src.copy(dest);
        }
        stored = '$nid/$fname';
      }
      added.add(Item(
        id: nid, type: o.type, name: name, color: o.color, opacity: o.opacity,
        parentId: o.parentId == null ? null : idMap[o.parentId],
        text: o.text, stored: stored, size: o.size,
        order: base + i, created: o.created, expanded: o.expanded,
      ));
      onProgress(0.6 + 0.35 * i / incoming.length);
    }
    items.addAll(added);
    await save();
    return added.length;
  }

  // Copies an item (and everything inside it, for buttons) to another page.
  Future<void> copyTree(Item root, String? newParent) async {
    final list = <Item>[];
    void walk(Item i) {
      list.add(i);
      for (final c in items.where((e) => e.parentId == i.id).toList()) {
        walk(c);
      }
    }

    walk(root);
    final idMap = <String, String>{};
    final copies = <Item>[];
    var seq = 0;
    for (final o in list) {
      final nid = '${newId()}${seq++}';
      String? stored;
      if (o.type == 'file' && o.stored != null) {
        try {
          final dir = Directory(p.join(filesDir.path, nid));
          await dir.create(recursive: true);
          stored = '$nid/${p.basename(o.stored!)}';
          await File(filePath(o)).copy(p.join(filesDir.path, stored));
        } catch (_) {
          continue; // original file missing: skip it
        }
      }
      idMap[o.id] = nid;
      copies.add(Item(
        id: nid, type: o.type, name: o.name, color: o.color, opacity: o.opacity,
        parentId: identical(o, root) ? newParent : idMap[o.parentId],
        text: o.text, stored: stored, size: o.size,
        order: identical(o, root) ? nextOrder() : o.order,
        created: DateTime.now().millisecondsSinceEpoch,
      ));
    }
    items.addAll(copies);
    await save();
  }
}

final store = Store();

// ───────────────────────── Progress ring state (backup) ─────────────────────────

class Prog {
  final double? value; // null = indeterminate
  const Prog(this.value);
}

final ValueNotifier<Prog?> prog = ValueNotifier<Prog?>(null);

// ───────────────────────── "Pick a page" mode (copy / receive shared) ─────────────────────────

class PickConfig {
  final String label;
  final String actionLabel;
  final Future<String> Function(String? parentId) onPick;
  const PickConfig({required this.label, required this.actionLabel, required this.onPick});
}

Route<void> pickRoute(PickConfig cfg) => MaterialPageRoute(
      settings: const RouteSettings(name: 'pick'),
      builder: (_) => VaultPage(parentId: null, title: 'Home', pick: cfg),
    );

void startCopy(Item it) {
  navKey.currentState?.push(pickRoute(PickConfig(
    label: 'Copying "${itemLabel(it)}". Open a page, then tap Paste here.',
    actionLabel: 'Paste here',
    onPick: (parent) async {
      await store.copyTree(it, parent);
      return 'Copied.';
    },
  )));
}

Future<String> saveIncoming(List<Map<String, String>> list, String? parent) async {
  var ok = 0, failed = 0;
  for (final m in list) {
    try {
      if (m['kind'] == 'text') {
        final t = m['text'] ?? '';
        final subj = (m['subject'] ?? '').trim();
        store.items.add(Item(
          id: store.newId(), type: 'note', name: subj, color: palette[9], opacity: 0,
          parentId: parent, text: t, order: store.nextOrder(),
          created: DateTime.now().millisecondsSinceEpoch,
        ));
      } else {
        final id = store.newId();
        final name = safeName(m['name'] ?? 'file');
        final dir = Directory(p.join(store.filesDir.path, id));
        await dir.create(recursive: true);
        final dest = p.join(dir.path, name);
        final size = await native.invokeMethod<int>('copyUri', {'uri': m['uri'], 'dest': dest});
        store.items.add(Item(
          id: id, type: 'file', name: name, color: palette[0], opacity: 0, parentId: parent,
          stored: '$id/$name', size: size ?? 0, order: store.nextOrder(),
          created: DateTime.now().millisecondsSinceEpoch,
        ));
      }
      ok++;
    } catch (_) {
      failed++;
    }
  }
  await store.save();
  return failed == 0 ? '$ok item(s) added.' : '$ok added, $failed failed.';
}

bool _checking = false;

Future<void> checkShared() async {
  if (_checking || navKey.currentState == null) return;
  _checking = true;
  try {
    final raw = await native.invokeMethod<List<dynamic>>('takeShared');
    if (raw != null && raw.isNotEmpty) {
      final list = raw.map((e) => Map<String, String>.from(e as Map)).toList();
      navKey.currentState?.push(pickRoute(PickConfig(
        label: '${list.length} item(s) received. Open a page, then tap Add here.',
        actionLabel: 'Add here',
        onPick: (parent) => saveIncoming(list, parent),
      )));
    }
  } catch (_) {
  } finally {
    _checking = false;
  }
}

// ───────────────────────── Small animated popup menu ─────────────────────────

class MenuEntry {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool danger;
  const MenuEntry(this.icon, this.label, this.onTap, {this.danger = false});
}

class _MenuLayout extends SingleChildLayoutDelegate {
  final Rect anchor;
  final bool up;
  _MenuLayout(this.anchor, this.up);

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints c) =>
      BoxConstraints.loose(Size(c.maxWidth - 16, c.maxHeight - 16));

  @override
  Offset getPositionForChild(Size size, Size child) {
    double x = anchor.right - child.width;
    final maxX = size.width - child.width - 8;
    if (x > maxX) x = maxX;
    if (x < 8) x = 8;
    final below = anchor.bottom + 4;
    final above = anchor.top - child.height - 4;
    double y;
    if (up) {
      y = above >= 8 ? above : below;
    } else {
      y = (below + child.height <= size.height - 8) ? below : above;
    }
    final maxY = size.height - child.height - 8;
    if (y > maxY) y = maxY;
    if (y < 8) y = 8;
    return Offset(x, y);
  }

  @override
  bool shouldRelayout(_MenuLayout old) => old.anchor != anchor || old.up != up;
}

Future<void> showAnchoredMenu(BuildContext anchorCtx, List<MenuEntry> entries,
    {bool up = false, double gap = 0}) {
  final box = anchorCtx.findRenderObject() as RenderBox;
  final rect = (box.localToGlobal(Offset.zero) & box.size).inflate(gap);
  final dark = isDarkCtx(anchorCtx);
  final bg = dark ? const Color(0xFF222A3D) : Colors.white;
  final fg = dark ? const Color(0xFFE8ECF6) : const Color(0xFF1D2433);

  return showGeneralDialog(
    context: anchorCtx,
    barrierDismissible: true,
    barrierLabel: 'menu',
    barrierColor: Colors.transparent,
    transitionDuration: const Duration(milliseconds: 120),
    pageBuilder: (ctx, a1, a2) {
      final menu = Material(
        color: bg,
        elevation: 8,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: IntrinsicWidth(
          child: ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 150),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final e in entries)
                  InkWell(
                    onTap: () {
                      Navigator.of(ctx).pop();
                      e.onTap();
                    },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                      child: Row(children: [
                        Icon(e.icon, size: 18, color: e.danger ? const Color(0xFFE53935) : fg),
                        const SizedBox(width: 10),
                        Text(e.label,
                            style: TextStyle(
                                fontSize: 14.5,
                                color: e.danger ? const Color(0xFFE53935) : fg)),
                      ]),
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
      return CustomSingleChildLayout(delegate: _MenuLayout(rect, up), child: menu);
    },
    transitionBuilder: (ctx, anim, sec, child) =>
        FadeTransition(opacity: CurvedAnimation(parent: anim, curve: Curves.easeOut), child: child),
  );
}

// ───────────────────────── App ─────────────────────────

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await store.init();
  native.setMethodCallHandler((call) async {
    if (call.method == 'shared') await checkShared();
    return null;
  });
  runApp(const VaultApp());
  WidgetsBinding.instance.addPostFrameCallback(
      (_) => Future.delayed(const Duration(milliseconds: 400), checkShared));
}

class VaultApp extends StatelessWidget {
  const VaultApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'My Notes',
        navigatorKey: navKey,
        debugShowCheckedModeBanner: false,
        theme: ThemeData(colorSchemeSeed: const Color(0xFF1E88E5), useMaterial3: true),
        darkTheme: ThemeData(
            colorSchemeSeed: const Color(0xFF1E88E5),
            brightness: Brightness.dark,
            useMaterial3: true),
        home: const VaultPage(parentId: null, title: 'My Notes', isRoot: true),
      );
}

// Stretches a radial gradient horizontally.
class _Elliptical extends GradientTransform {
  final double sx;
  const _Elliptical(this.sx);
  @override
  Matrix4? transform(Rect bounds, {TextDirection? textDirection}) {
    final cx = bounds.left + bounds.width * 0.3;
    final m = Matrix4.identity();
    m.setEntry(0, 0, sx);
    m.setEntry(0, 3, cx - sx * cx);
    return m;
  }
}

// ───────────────────────── Colour swatches ─────────────────────────

class ColorPalette extends StatelessWidget {
  final int selected;
  final ValueChanged<int> onPick;
  const ColorPalette({super.key, required this.selected, required this.onPick});

  @override
  Widget build(BuildContext context) => Wrap(spacing: 10, runSpacing: 10, children: [
        for (final col in palette)
          GestureDetector(
            onTap: () => onPick(col),
            child: CircleAvatar(
              radius: 15,
              backgroundColor: Color(col),
              child: selected == col ? const Icon(Icons.check, color: Colors.white, size: 17) : null,
            ),
          ),
      ]);
}

({Color bg, Color fg, Color mut}) noteColors(BuildContext c, Item it) {
  final bg = Color.alphaBlend(Color(it.color).withValues(alpha: it.opacity / 100.0), cardOf(c));
  final bgIsDark = ThemeData.estimateBrightnessForColor(bg) == Brightness.dark;
  final fg = bgIsDark ? const Color(0xFFE8ECF6) : const Color(0xFF1D2433);
  return (bg: bg, fg: fg, mut: fg.withValues(alpha: 0.65));
}

// ───────────────────────── Page (Home, every button, and "pick a page" mode) ─────────────────────────

DateTime? _lastBack;

class VaultPage extends StatelessWidget {
  final String? parentId;
  final String title;
  final PickConfig? pick;
  final bool isRoot;
  const VaultPage({super.key, required this.parentId, required this.title, this.pick, this.isRoot = false});

  bool get inPick => pick != null;

  void _rootBack(BuildContext c, bool didPop) {
    if (didPop) return;
    final now = DateTime.now();
    if (_lastBack != null && now.difference(_lastBack!) < const Duration(seconds: 2)) {
      SystemNavigator.pop();
      return;
    }
    _lastBack = now;
    showPressAgain();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final all = store.childrenOf(parentId);
        final pageBg = pageBgOf(context);

        Widget body;
        if (all.isEmpty) {
          body = Center(
              child: Text(
                  inPick ? 'No items here.\nYou can add to this page or open a button.' : 'Nothing here yet.\nTap + to add.',
                  textAlign: TextAlign.center));
        } else if (inPick) {
          body = ListView.builder(
            padding: const EdgeInsets.only(top: 6, bottom: 24),
            itemCount: all.length,
            itemBuilder: (c, i) => _tile(c, all[i]),
          );
        } else {
          body = ReorderableListView.builder(
            // Long-press any item, then drag to put it where you want.
            padding: const EdgeInsets.only(top: 6, bottom: 110),
            itemCount: all.length,
            proxyDecorator: (child, i, a) => Material(color: Colors.transparent, elevation: 0, child: child),
            onReorder: (o, n) async {
              if (n > o) n -= 1;
              final m = all.removeAt(o);
              all.insert(n, m);
              for (var i = 0; i < all.length; i++) {
                all[i].order = i;
              }
              await store.save();
            },
            itemBuilder: (c, i) => KeyedSubtree(key: ValueKey(all[i].id), child: _tile(c, all[i])),
          );
        }

        final scaffold = Scaffold(
          backgroundColor: pageBg,
          appBar: AppBar(
            title: Text(title),
            backgroundColor: pageBg,
            surfaceTintColor: Colors.transparent,
            scrolledUnderElevation: 0,
          ),
          body: inPick ? Column(children: [_banner(), Expanded(child: body)]) : body,
          floatingActionButton: inPick ? null : _fab(context),
          bottomNavigationBar: inPick ? _pickBar(context, pageBg) : null,
        );

        if (isRoot) {
          return PopScope(
            canPop: false,
            onPopInvokedWithResult: (didPop, result) => _rootBack(context, didPop),
            child: scaffold,
          );
        }
        return scaffold;
      },
    );
  }

  Widget _tile(BuildContext c, Item it) =>
      it.type == 'button' ? _buttonTile(c, it) : (it.type == 'note' ? _noteTile(c, it) : _fileTile(c, it));

  // ── Pick-a-page mode ──
  Widget _banner() => Material(
        color: const Color(0xFF1F7A4D),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(children: [
            const Icon(Icons.subdirectory_arrow_right, color: Colors.white, size: 20),
            const SizedBox(width: 10),
            Expanded(child: Text(pick!.label, style: const TextStyle(color: Colors.white, fontSize: 14))),
          ]),
        ),
      );

  Widget _pickBar(BuildContext context, Color bg) => ColoredBox(
        color: bg,
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Row(children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => itemDialog(context, type: 'button', parentId: parentId),
                  icon: const Icon(Icons.add),
                  label: const Text('New button'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.icon(
                  onPressed: () => _pickDone(context),
                  icon: const Icon(Icons.check),
                  label: Text(pick!.actionLabel),
                ),
              ),
            ]),
          ),
        ),
      );

  Future<void> _pickDone(BuildContext context) async {
    final cfg = pick!;
    _busy(context, 'Working…');
    String msg;
    try {
      msg = await cfg.onPick(parentId);
    } catch (e) {
      msg = 'Failed: $e';
    }
    final nav = navKey.currentState;
    if (nav == null) return;
    nav.pop(); // busy dialog
    nav.popUntil((r) => r.settings.name != 'pick');
    final ctx = navKey.currentContext;
    if (ctx != null) toast(ctx, msg);
  }

  // ── Floating add button (fills with bubbles during backup / restore) ──
  Widget _fab(BuildContext context) => BubbleFab(
        onTap: (fabCtx) {
          if (prog.value != null) {
            toast(context, 'Please wait…');
          } else {
            _menu(context, fabCtx);
          }
        },
      );

  void _menu(BuildContext context, BuildContext fabCtx) {
    showAnchoredMenu(
      fabCtx,
      [
        MenuEntry(Icons.smart_button_outlined, 'Add Button',
            () => itemDialog(context, type: 'button', parentId: parentId)),
        MenuEntry(Icons.sticky_note_2_outlined, 'Add Note',
            () => itemDialog(context, type: 'note', parentId: parentId)),
        MenuEntry(Icons.attach_file, 'Add File', () => _addFiles(context)),
        MenuEntry(Icons.photo_camera_outlined, 'Camera', () => _takePhoto(context)),
        MenuEntry(Icons.backup_outlined, 'Backup', () => _backupMenu(context, fabCtx)),
      ],
      up: true,
      gap: 8,
    );
  }

  void _backupMenu(BuildContext context, BuildContext fabCtx) {
    showAnchoredMenu(
      fabCtx,
      [
        MenuEntry(Icons.upload_file, 'Create Backup', () => _createBackup(context)),
        MenuEntry(Icons.restore, 'Restore Backup', () => _restoreBackup(context)),
      ],
      up: true,
      gap: 8,
    );
  }

  // ── Tiles ──
  Widget _buttonTile(BuildContext c, Item it) {
    final base = Color(it.color);
    Color mixW(double k) => Color.lerp(Colors.white, base, k)!;
    Color mixB(double k) => Color.lerp(Colors.black, base, k)!;
    final hi = mixW(0.78), edge = mixB(0.92);
    final maxW = MediaQuery.of(c).size.width - 32;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
      child: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(minWidth: 150, maxWidth: maxW),
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              gradient: RadialGradient(
                center: const Alignment(-0.4, -0.7),
                radius: 1.5,
                colors: [hi, base, edge],
                stops: const [0.0, 0.48, 1.0],
                transform: const _Elliptical(2.4),
              ),
              boxShadow: [
                BoxShadow(color: base.withValues(alpha: 0.5), blurRadius: 22, offset: const Offset(0, 12)),
                BoxShadow(color: Colors.black.withValues(alpha: 0.10), blurRadius: 6, offset: const Offset(0, 3)),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: Material(
                type: MaterialType.transparency,
                child: InkWell(
                  onTap: () => Navigator.push(
                    c,
                    MaterialPageRoute(
                      settings: inPick ? const RouteSettings(name: 'pick') : const RouteSettings(),
                      builder: (_) => VaultPage(parentId: it.id, title: it.name, pick: pick),
                    ),
                  ),
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 34, vertical: 16),
                        child: Text(
                          it.name,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                            shadows: [Shadow(color: Color(0x66000000), blurRadius: 2, offset: Offset(0, 1))],
                          ),
                        ),
                      ),
                      if (!inPick)
                        Positioned(
                          right: 2, top: 0, bottom: 0,
                          child: Center(child: _more(c, it, iconColor: Colors.white70)),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _chevron(Item it, Color color) => InkResponse(
        radius: 18,
        onTap: () {
          it.expanded = !it.expanded;
          store.save();
        },
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Icon(it.expanded ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down, size: 24, color: color),
        ),
      );

  Widget _noteTile(BuildContext c, Item it) {
    final col = noteColors(c, it);
    final title = it.name.trim();
    final body = (it.text ?? '').trim();
    final expanded = it.expanded && !inPick;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: col.bg,
          borderRadius: BorderRadius.circular(14),
          boxShadow: [BoxShadow(color: lineOf(c), offset: const Offset(0, 2), blurRadius: 0)],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              onTap: inPick
                  ? null
                  : () => Navigator.push(c, MaterialPageRoute(builder: (_) => NotePage(id: it.id))),
              child: Stack(
                children: [
                  Positioned(
                    left: 0, top: 0, bottom: 0, width: 6,
                    child: ColoredBox(color: Color(it.color)),
                  ),
                  Padding(
                    padding: EdgeInsets.fromLTRB(22, 14, inPick ? 14 : 76, 14),
                    child: AnimatedSize(
                      duration: const Duration(milliseconds: 150),
                      alignment: Alignment.topLeft,
                      child: SizedBox(
                        width: double.infinity,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (title.isNotEmpty) Text(title, style: TextStyle(fontSize: 18, color: col.fg)),
                            if (title.isNotEmpty && expanded && body.isNotEmpty) const SizedBox(height: 6),
                            if (body.isNotEmpty && (title.isEmpty || expanded))
                              Text(
                                body,
                                maxLines: expanded ? null : 2,
                                overflow: expanded ? TextOverflow.visible : TextOverflow.ellipsis,
                                style: TextStyle(
                                    fontSize: title.isEmpty ? 17 : 15,
                                    color: title.isEmpty ? col.fg : col.mut),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  if (!inPick)
                    Positioned(
                      right: 2, top: 4,
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        _chevron(it, col.mut),
                        _more(c, it, iconColor: col.mut),
                      ]),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _fileTile(BuildContext c, Item it) {
    final col = noteColors(c, it);
    final fg = col.fg;
    final mut = col.mut;
    final img = isImage(it.name);
    final expanded = img && it.expanded && !inPick;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: col.bg,
          borderRadius: BorderRadius.circular(14),
          boxShadow: [BoxShadow(color: lineOf(c), offset: const Offset(0, 2), blurRadius: 0)],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              onTap: inPick ? null : () => _open(c, it),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
                child: Column(children: [
                  Row(children: [
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: Color(it.color),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: Colors.white.withValues(alpha: 0.35), width: 1),
                      ),
                      child: Icon(fileIcon(it.name), color: Colors.white, size: 24),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(it.name,
                            maxLines: 1, overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 16, color: fg)),
                        const SizedBox(height: 2),
                        Text(fmtSize(it.size), style: TextStyle(fontSize: 13, color: mut)),
                      ]),
                    ),
                    if (!inPick && img) _chevron(it, mut),
                    if (!inPick) _more(c, it, iconColor: mut),
                  ]),
                  AnimatedSize(
                    duration: const Duration(milliseconds: 150),
                    alignment: Alignment.topCenter,
                    child: expanded
                        ? Padding(
                            padding: const EdgeInsets.only(top: 10, right: 6),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(10),
                              child: ConstrainedBox(
                                constraints: const BoxConstraints(maxHeight: 320),
                                child: Image.file(
                                  File(store.filePath(it)),
                                  key: ValueKey('${it.stored}-${it.size}'),
                                  width: double.infinity,
                                  fit: BoxFit.contain,
                                  cacheWidth: 1000,
                                  errorBuilder: (c, e, s) => Padding(
                                    padding: const EdgeInsets.all(16),
                                    child: Text('Cannot preview this image', style: TextStyle(color: mut)),
                                  ),
                                ),
                              ),
                            ),
                          )
                        : const SizedBox(width: double.infinity),
                  ),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ── 3-dot menu ──
  Widget _more(BuildContext c, Item it, {Color? iconColor}) => Builder(
        builder: (bc) => InkResponse(
          radius: 18,
          onTap: () => _itemMenu(bc, c, it),
          child: Padding(
            padding: const EdgeInsets.all(5),
            child: Icon(Icons.more_vert, size: 20, color: iconColor),
          ),
        ),
      );

  void _itemMenu(BuildContext anchor, BuildContext c, Item it) {
    final e = <MenuEntry>[];
    if (it.type == 'file') {
      e.add(MenuEntry(Icons.apps, 'Open with…', () => _openWith(c, it)));
      e.add(MenuEntry(Icons.edit_outlined, 'Edit',
          () => itemDialog(c, type: 'file', parentId: it.parentId, existing: it)));
      e.add(MenuEntry(Icons.share_outlined, 'Share', () => _share(c, it)));
    } else if (it.type == 'note') {
      e.add(MenuEntry(Icons.edit_outlined, 'Edit',
          () => itemDialog(c, type: 'note', parentId: it.parentId, existing: it)));
      e.add(MenuEntry(Icons.share_outlined, 'Share', () => _share(c, it)));
    } else {
      e.add(MenuEntry(Icons.edit_outlined, 'Edit',
          () => itemDialog(c, type: 'button', parentId: it.parentId, existing: it)));
    }
    e.add(MenuEntry(Icons.copy_outlined, 'Copy', () => startCopy(it)));
    e.add(MenuEntry(Icons.delete_outline, 'Delete', () => _delete(c, it), danger: true));
    showAnchoredMenu(anchor, e);
  }

  Future<void> _delete(BuildContext c, Item it) async {
    final ok = await showDialog<bool>(
        context: c,
        builder: (d) => AlertDialog(
              title: Text('Delete "${itemLabel(it)}"?'),
              content: Text(it.type == 'button'
                  ? 'Everything inside this button will also be deleted.'
                  : 'This cannot be undone.'),
              actions: [
                TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')),
                FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Delete')),
              ],
            ));
    if (ok == true) await store.delete(it);
  }

  // ── Files ──
  Future<bool> _exists(BuildContext c, Item it) async {
    if (!await File(store.filePath(it)).exists()) {
      if (c.mounted) toast(c, 'File is missing from app storage.');
      return false;
    }
    return true;
  }

  // Pictures open in the built-in viewer/editor; everything else in the default app.
  Future<void> _open(BuildContext c, Item it) async {
    if (!await _exists(c, it)) return;
    if (isImage(it.name)) {
      if (c.mounted) {
        Navigator.push(c, MaterialPageRoute(builder: (_) => ImageViewerPage(id: it.id)));
      }
      return;
    }
    final r = await OpenFilex.open(store.filePath(it));
    if (r.type != ResultType.done && c.mounted) toast(c, r.message);
  }

  // Always shows the full list of apps that can open this file.
  Future<void> _openWith(BuildContext c, Item it) async {
    if (!await _exists(c, it)) return;
    try {
      await native.invokeMethod('openWith', {'path': store.filePath(it)});
    } on PlatformException catch (e) {
      if (c.mounted) toast(c, 'Could not open: ${e.message}');
    }
  }

  Future<void> _share(BuildContext c, Item it) async {
    try {
      if (it.type == 'file') {
        if (!await _exists(c, it)) return;
        await native.invokeMethod('shareFiles', {'paths': [store.filePath(it)]});
      } else {
        await native.invokeMethod('shareText', {'subject': it.name, 'text': it.text ?? ''});
      }
    } on PlatformException catch (e) {
      if (c.mounted) toast(c, 'Could not share: ${e.message}');
    }
  }

  Future<void> _addFiles(BuildContext c) async {
    final res = await FilePicker.platform.pickFiles(allowMultiple: true, type: FileType.any);
    if (res == null) return;
    if (c.mounted) toast(c, 'Copying ${res.files.length} file(s)…');
    var n = 0;
    for (final f in res.files) {
      if (f.path == null) continue;
      final src = File(f.path!);
      final id = store.newId();
      final name = safeName(f.name);
      final dir = Directory(p.join(store.filesDir.path, id));
      await dir.create(recursive: true);
      final dest = File(p.join(dir.path, name));
      await src.copy(dest.path); // permanent copy in the app's own folder
      try {
        await src.delete(); // remove the picker's temporary cache copy
      } catch (_) {}
      store.items.add(Item(
        id: id, type: 'file', name: name, color: palette[0], opacity: 0,
        parentId: parentId, stored: '$id/$name', size: await dest.length(),
        order: store.nextOrder(), created: DateTime.now().millisecondsSinceEpoch,
      ));
      n++;
    }
    await store.save();
    if (c.mounted) toast(c, '$n file(s) added.');
  }

  // ── Camera ──
  Future<void> _takePhoto(BuildContext c) async {
    try {
      final x = await ImagePicker().pickImage(source: ImageSource.camera);
      if (x == null) return;
      final id = store.newId();
      var ext = p.extension(x.path).toLowerCase();
      if (ext.isEmpty) ext = '.jpg';
      final name = 'IMG_${stampNow()}$ext';
      final dir = Directory(p.join(store.filesDir.path, id));
      await dir.create(recursive: true);
      final dest = File(p.join(dir.path, name));
      await File(x.path).copy(dest.path);
      try {
        await File(x.path).delete(); // camera's temporary copy
      } catch (_) {}
      store.items.add(Item(
        id: id, type: 'file', name: name, color: palette[0], opacity: 0,
        parentId: parentId, stored: '$id/$name', size: await dest.length(),
        order: store.nextOrder(), created: DateTime.now().millisecondsSinceEpoch,
      ));
      await store.save();
      if (c.mounted) toast(c, 'Photo added.');
    } catch (e) {
      if (c.mounted) toast(c, 'Camera error: $e');
    }
  }

  // ── Backup ──
  void _busy(BuildContext c, String msg) => showDialog(
      context: c,
      barrierDismissible: false,
      builder: (_) => PopScope(
            canPop: false,
            child: AlertDialog(
                content: Row(children: [
              const CircularProgressIndicator(),
              const SizedBox(width: 20),
              Expanded(child: Text(msg)),
            ])),
          ));

  Future<void> _createBackup(BuildContext c) async {
    if (prog.value != null) return;
    await Permission.storage.request(); // only matters on Android 9 and below
    prog.value = const Prog(0);
    String msg;
    try {
      final dl = Directory('/storage/emulated/0/Download');
      if (!await dl.exists()) await dl.create(recursive: true);
      final t = DateTime.now();
      String two(int v) => v.toString().padLeft(2, '0');
      final stamp = '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}-${two(t.minute)}-${two(t.second)}';
      final fname = 'My Notes Backup ($stamp).zip';
      final out = p.join(dl.path, fname);

      final rp = ReceivePort();
      await Isolate.spawn(_backupWorker, {
        'port': rp.sendPort,
        'data': store.dataFile.path,
        'files': store.filesDir.path,
        'out': out,
      }, onExit: rp.sendPort, onError: rp.sendPort);

      String? err;
      await for (final m in rp) {
        if (m is double) {
          prog.value = Prog(m);
        } else if (m == 'done') {
          break;
        } else if (m == null) {
          err = 'stopped unexpectedly';
          break;
        } else if (m is List) {
          err = m.first.toString();
          break;
        } else if (m is String) {
          err = m;
          break;
        }
      }
      rp.close();
      if (err != null) throw err;
      prog.value = const Prog(1);
      await Future.delayed(const Duration(milliseconds: 800));
      msg = 'Backup saved to Downloads:\n$fname';
    } catch (e) {
      msg = 'Backup failed: $e';
    }
    prog.value = null;
    final ctx = navKey.currentContext;
    if (ctx != null) toast(ctx, msg);
  }

  Future<void> _restoreBackup(BuildContext c) async {
    if (prog.value != null) return;
    final res = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['zip']);
    if (res == null || res.files.single.path == null || !c.mounted) return;
    final zipFile = File(res.files.single.path!);

    final ok = await showDialog<bool>(
        context: c,
        builder: (d) => AlertDialog(
              title: const Text('Restore backup?'),
              content: const Text(
                  'The backup will be added below your existing items. Nothing you have now will be changed or removed.'),
              actions: [
                TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')),
                FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Restore')),
              ],
            ));
    if (ok != true) return;

    prog.value = const Prog(0.05);
    final tmp = Directory(p.join(store.root.path, 'restore_tmp'));
    String msg;
    try {
      if (await tmp.exists()) await tmp.delete(recursive: true);
      await tmp.create(recursive: true);
      await _extractInBg(zipFile.path, tmp.path);
      prog.value = const Prog(0.6);

      if (!await File(p.join(tmp.path, 'data.json')).exists()) throw 'Not a valid backup';
      final n = await store.mergeBackup(tmp, (v) => prog.value = Prog(v));
      prog.value = const Prog(1);
      await Future.delayed(const Duration(milliseconds: 800));
      try {
        await zipFile.delete(); // picker's cache copy
      } catch (_) {}
      msg = '$n item(s) restored below your existing items.';
    } catch (e) {
      msg = 'Restore failed: $e';
    }
    try {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    } catch (_) {}
    prog.value = null;
    navKey.currentState?.popUntil((r) => r.isFirst);
    final ctx = navKey.currentContext;
    if (ctx != null) toast(ctx, msg);
  }
}

// Runs in a background isolate so the animation stays smooth.
void _backupWorker(Map<String, dynamic> a) {
  final SendPort port = a['port'] as SendPort;
  try {
    final dataFile = File(a['data'] as String);
    final filesDir = Directory(a['files'] as String);
    final files = filesDir.existsSync()
        ? filesDir.listSync(recursive: true).whereType<File>().toList()
        : <File>[];
    var total = 0;
    for (final f in files) {
      total += f.lengthSync();
    }
    if (total == 0) total = 1;
    final enc = ZipFileEncoder();
    enc.create(a['out'] as String);
    enc.addFile(dataFile, 'data.json');
    var done = 0;
    for (final f in files) {
      final rel = p.relative(f.path, from: filesDir.path).replaceAll('\\', '/');
      enc.addFile(f, 'files/$rel');
      done += f.lengthSync();
      port.send(done / total);
    }
    enc.close();
    port.send('done');
  } catch (e) {
    port.send('error: $e');
  }
}

Future<void> _extractInBg(String zipPath, String dest) =>
    Isolate.run(() => extractFileToDisk(zipPath, dest));

// ───────────────────────── Full note view ─────────────────────────

class NotePage extends StatelessWidget {
  final String id;
  const NotePage({super.key, required this.id});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final found = store.items.where((e) => e.id == id).toList();
        if (found.isEmpty) return Scaffold(backgroundColor: pageBgOf(context), appBar: AppBar());
        final it = found.first;
        final col = noteColors(context, it);
        final pageBg = pageBgOf(context);
        return Scaffold(
          backgroundColor: pageBg,
          appBar: AppBar(
            title: Text(it.name.trim().isEmpty ? 'Note' : it.name.trim()),
            backgroundColor: pageBg,
            surfaceTintColor: Colors.transparent,
            scrolledUnderElevation: 0,
            actions: [
              IconButton(
                icon: const Icon(Icons.edit_outlined),
                onPressed: () => itemDialog(context, type: 'note', parentId: it.parentId, existing: it),
              ),
            ],
          ),
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: col.bg,
                borderRadius: BorderRadius.circular(14),
                boxShadow: [BoxShadow(color: lineOf(context), offset: const Offset(0, 2), blurRadius: 0)],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: Stack(children: [
                  Positioned(left: 0, top: 0, bottom: 0, width: 6, child: ColoredBox(color: Color(it.color))),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 18, 18, 18),
                    child: SizedBox(
                      width: double.infinity,
                      child: SelectableText(
                        it.text ?? '',
                        style: TextStyle(fontSize: 17, height: 1.45, color: col.fg),
                      ),
                    ),
                  ),
                ]),
              ),
            ),
          ),
        );
      },
    );
  }
}

// ───────────────────────── Add / edit dialog (buttons + notes) ─────────────────────────

Future<void> itemDialog(BuildContext ctx,
    {required String type, String? parentId, Item? existing}) async {
  final name = TextEditingController(text: existing?.name ?? '');
  final text = TextEditingController(text: existing?.text ?? '');
  final isNote = type == 'note';
  final isFile = type == 'file';
  final tinted = isNote || isFile; // colour + transparency options
  int color = existing?.color ?? (isNote ? palette[9] : palette[0]);
  int opacity = existing?.opacity ?? 0;

  await showDialog(
    context: ctx,
    builder: (d) => StatefulBuilder(
      builder: (d, set) => AlertDialog(
        title: Text(existing == null ? (isNote ? 'New note' : 'New button') : 'Edit'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            TextField(
                controller: name,
                autofocus: !isNote,
                decoration: InputDecoration(
                    labelText: isFile ? 'File name' : (isNote ? 'Title (optional)' : 'Button name'))),
            if (isNote) ...[
              const SizedBox(height: 12),
              TextField(
                  controller: text,
                  maxLines: 8,
                  minLines: 4,
                  decoration: const InputDecoration(labelText: 'Note', border: OutlineInputBorder())),
            ],
            const SizedBox(height: 16),
            const Text('Colour'),
            const SizedBox(height: 8),
            ColorPalette(selected: color, onPick: (v) => set(() => color = v)),
            if (tinted) ...[
              const SizedBox(height: 16),
              Text('Transparency: $opacity%'),
              Slider(
                value: opacity.toDouble(),
                min: 0,
                max: 100,
                divisions: 5,
                label: '$opacity',
                onChanged: (v) => set(() => opacity = v.round()),
              ),
              const Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [Text('0'), Text('20'), Text('40'), Text('60'), Text('80'), Text('100')],
              ),
              const SizedBox(height: 10),
              Container(
                height: isFile ? 60 : 44,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Color(color).withValues(alpha: opacity / 100.0),
                  border: isFile ? null : Border.all(color: Color(color), width: 2),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: isFile
                    ? Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                        Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            color: Color(color),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: Colors.white.withValues(alpha: 0.35)),
                          ),
                          child: Icon(fileIcon(existing?.name ?? ''), color: Colors.white, size: 22),
                        ),
                        const SizedBox(width: 10),
                        const Text('Preview'),
                      ])
                    : const Text('Preview'),
              ),
            ],
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d), child: const Text('Cancel')),
          FilledButton(
            onPressed: () async {
              final emptyName = name.text.trim().isEmpty;
              final emptyText = text.text.trim().isEmpty;
              if (isNote ? (emptyName && emptyText) : emptyName) return;
              if (existing != null && isFile) {
                var nn = safeName(name.text);
                if (p.extension(nn).isEmpty) nn += p.extension(existing.name);
                if (nn != existing.name) {
                  try {
                    final newStored = '${p.dirname(existing.stored!)}/$nn';
                    await File(store.filePath(existing))
                        .rename(p.join(store.filesDir.path, newStored));
                    existing.stored = newStored;
                    existing.name = nn;
                  } catch (_) {
                    if (ctx.mounted) toast(ctx, 'Could not rename the file.');
                  }
                }
                existing.color = color;
                existing.opacity = opacity;
              } else if (existing != null) {
                existing.name = name.text.trim();
                existing.color = color;
                if (isNote) {
                  existing.text = text.text;
                  existing.opacity = opacity;
                }
              } else {
                store.items.add(Item(
                  id: store.newId(), type: type, name: name.text.trim(), color: color,
                  opacity: opacity, parentId: parentId, text: isNote ? text.text : null,
                  order: store.nextOrder(), created: DateTime.now().millisecondsSinceEpoch,
                ));
              }
              await store.save();
              if (d.mounted) Navigator.pop(d);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    ),
  );
}

// ───────────────────────── Bubble-fill + button ─────────────────────────

class BubbleFab extends StatefulWidget {
  final void Function(BuildContext fabCtx) onTap;
  const BubbleFab({super.key, required this.onTap});

  @override
  State<BubbleFab> createState() => _BubbleFabState();
}

class _BubbleFabState extends State<BubbleFab> with SingleTickerProviderStateMixin {
  late final AnimationController _ctl =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 2400));
  double _shown = 0;

  @override
  void initState() {
    super.initState();
    _ctl.addListener(_tick);
    prog.addListener(_sync);
    _sync();
  }

  @override
  void dispose() {
    prog.removeListener(_sync);
    _ctl.dispose();
    super.dispose();
  }

  void _sync() {
    if (prog.value != null) {
      if (!_ctl.isAnimating) {
        _shown = 0;
        _ctl.repeat();
      }
    } else {
      _ctl.stop();
      _shown = 0;
    }
  }

  void _tick() {
    final pr = prog.value;
    if (pr == null) return;
    final v = pr.value;
    if (v == null) {
      _shown = _ctl.value; // unknown progress: keep filling from bottom to top
    } else {
      _shown += (v - _shown) * 0.12;
      if ((v - _shown).abs() < 0.01) _shown = v;
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ValueListenableBuilder<Prog?>(
      valueListenable: prog,
      builder: (context, pr, _) {
        final active = pr != null;
        final pct = pr?.value;
        return SizedBox(
          width: 56,
          height: 56,
          child: Builder(
            builder: (fabCtx) => Material(
              color: cs.primaryContainer,
              elevation: 6,
              shadowColor: Colors.black,
              surfaceTintColor: Colors.transparent,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: () => widget.onTap(fabCtx),
                child: AnimatedBuilder(
                  animation: _ctl,
                  builder: (context, _) {
                    final level = active ? _shown.clamp(0.0, 1.0) : 0.0;
                    final fg = level > 0.55 ? cs.onPrimary : cs.onPrimaryContainer;
                    return Stack(fit: StackFit.expand, children: [
                      if (active)
                        CustomPaint(painter: _LiquidPainter(level: level, t: _ctl.value, color: cs.primary)),
                      Center(
                        child: (active && pct != null)
                            ? Text('${(pct * 100).round()}%',
                                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: fg))
                            : Icon(Icons.add, size: 28, color: fg),
                      ),
                    ]);
                  },
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _LiquidPainter extends CustomPainter {
  final double level; // 0..1, bottom to top
  final double t; // 0..1 looping animation clock
  final Color color;
  const _LiquidPainter({required this.level, required this.t, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final top = h * (1 - level);
    final amp = 3.0 * (level * 8).clamp(0.0, 1.0) * ((1 - level) * 8).clamp(0.0, 1.0);

    final path = Path()..moveTo(0, h);
    for (double x = 0; x <= w; x += 2) {
      final y = top + math.sin(x / w * 2 * math.pi * 1.5 + t * 2 * math.pi * 3) * amp;
      path.lineTo(x, y);
    }
    path.lineTo(w, h);
    path.close();
    canvas.drawPath(path, Paint()..color = color.withValues(alpha: 0.9));

    final span = h - top;
    if (span > 6) {
      final bp = Paint()..color = Colors.white.withValues(alpha: 0.55);
      for (var i = 0; i < 6; i++) {
        final bx = w * (0.18 + 0.64 * ((i * 0.381) % 1.0)) + math.sin((t * 2 + i) * math.pi) * 2;
        final r = 2.0 + (i % 3) * 1.4;
        final k = ((t * (1 + i % 2)) + i / 6.0) % 1.0;
        final by = h - k * span;
        if (by - r > top + amp) canvas.drawCircle(Offset(bx, by), r, bp);
      }
    }
  }

  @override
  bool shouldRepaint(_LiquidPainter old) => true;
}

// ───────────────────────── Built-in image viewer / editor ─────────────────────────

class ImageViewerPage extends StatefulWidget {
  final String id;
  const ImageViewerPage({super.key, required this.id});

  @override
  State<ImageViewerPage> createState() => _ImageViewerPageState();
}

class _ImageViewerPageState extends State<ImageViewerPage> {
  File? _origCopy; // untouched copy made before the first edit, for Revert
  String? _origStored;
  bool _busy = false;

  Item? get _it {
    for (final e in store.items) {
      if (e.id == widget.id) return e;
    }
    return null;
  }

  @override
  void dispose() {
    try {
      _origCopy?.deleteSync();
    } catch (_) {}
    super.dispose();
  }

  Future<void> _refresh() async {
    imageCache.clear();
    imageCache.clearLiveImages();
    await store.save();
    if (mounted) setState(() {});
  }

  Future<void> _crop() async {
    final it = _it;
    if (it == null || _busy) return;
    final path = store.filePath(it);
    if (!File(path).existsSync()) {
      toast(context, 'File is missing from app storage.');
      return;
    }
    setState(() => _busy = true);
    try {
      final ext = p.extension(path).toLowerCase();
      final cropped = await ImageCropper().cropImage(
        sourcePath: path,
        compressFormat: ext == '.png' ? ImageCompressFormat.png : ImageCompressFormat.jpg,
        compressQuality: 95,
        uiSettings: [
          AndroidUiSettings(
            toolbarTitle: 'Edit picture',
            toolbarColor: const Color(0xFF161B28),
            toolbarWidgetColor: Colors.white,
            activeControlsWidgetColor: const Color(0xFF1E88E5),
            initAspectRatio: CropAspectRatioPreset.original,
            lockAspectRatio: false,
          ),
        ],
      );
      if (cropped == null) return; // user cancelled

      if (_origCopy == null) {
        final tmp = await getTemporaryDirectory();
        final oc = File(p.join(tmp.path, 'orig_${it.id}$ext'));
        await File(path).copy(oc.path);
        _origCopy = oc;
        _origStored = it.stored;
      }

      final keepExt = ext == '.jpg' || ext == '.jpeg' || ext == '.png';
      final base = p.basename(it.stored!);
      final newBase = keepExt ? base : '${p.basenameWithoutExtension(base)}.jpg';
      final dir = p.dirname(it.stored!);
      final dest = File(p.join(store.filesDir.path, dir, newBase));
      await File(cropped.path).copy(dest.path);
      try {
        await File(cropped.path).delete();
      } catch (_) {}
      if (dest.path != path) {
        try {
          await File(path).delete();
        } catch (_) {}
      }
      it.stored = '$dir/$newBase';
      it.name = newBase;
      it.size = await dest.length();
      await _refresh();
    } catch (e) {
      if (mounted) toast(context, 'Could not edit picture: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _revert() async {
    final it = _it;
    final oc = _origCopy;
    final os = _origStored;
    if (it == null || oc == null || os == null || _busy) return;
    setState(() => _busy = true);
    try {
      final dest = File(p.join(store.filesDir.path, os));
      final cur = store.filePath(it);
      await oc.copy(dest.path);
      if (cur != dest.path) {
        try {
          await File(cur).delete();
        } catch (_) {}
      }
      it.stored = os;
      it.name = p.basename(os);
      it.size = await dest.length();
      await _refresh();
      if (mounted) toast(context, 'Original restored.');
    } catch (e) {
      if (mounted) toast(context, 'Could not revert: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final it = _it;
    if (it == null) {
      return Scaffold(backgroundColor: Colors.black, appBar: AppBar());
    }
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        title: Text(it.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 16)),
        actions: [
          if (_origCopy != null)
            IconButton(icon: const Icon(Icons.undo), tooltip: 'Revert to original', onPressed: _busy ? null : _revert),
          IconButton(icon: const Icon(Icons.crop), tooltip: 'Crop / edit', onPressed: _busy ? null : _crop),
        ],
      ),
      body: Stack(children: [
        Positioned.fill(
          child: InteractiveViewer(
            minScale: 1,
            maxScale: 6,
            child: Center(
              child: Image.file(
                File(store.filePath(it)),
                key: ValueKey('${it.stored}-${it.size}'),
                fit: BoxFit.contain,
                errorBuilder: (c, e, st) => const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text('Cannot display this image',
                      style: TextStyle(color: Colors.white70), textAlign: TextAlign.center),
                ),
              ),
            ),
          ),
        ),
        if (_busy) const Positioned(top: 0, left: 0, right: 0, child: LinearProgressIndicator()),
      ]),
      bottomNavigationBar: ColoredBox(
        color: Colors.black,
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
            child: Row(children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: _busy ? null : _crop,
                  icon: const Icon(Icons.crop),
                  label: const Text('Crop / Edit'),
                ),
              ),
              if (_origCopy != null) ...[
                const SizedBox(width: 12),
                OutlinedButton.icon(
                  onPressed: _busy ? null : _revert,
                  icon: const Icon(Icons.undo),
                  label: const Text('Revert'),
                ),
              ],
            ]),
          ),
        ),
      ),
    );
  }
}
