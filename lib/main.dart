
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:window_manager/window_manager.dart';

final ValueNotifier<ThemeMode> appTheme = ValueNotifier(ThemeMode.system);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (Platform.isWindows) {
    await windowManager.ensureInitialized();
    await windowManager.waitUntilReadyToShow(
      const WindowOptions(size: Size(1100, 780), minimumSize: Size(760, 540)),
      () async {
        await _WindowPlacement.restore();
        await windowManager.show();
      },
    );
  }
  runApp(const MyCattlesApp());
}

// ウィンドウ配置は機密情報を含まない独立したローカル設定として保存する。
class _WindowPlacement {
  static Future<File> _file() async => File(
    '${(await getApplicationSupportDirectory()).path}${Platform.pathSeparator}window_placement.json');

  static Future<void> restore() async {
    if (!Platform.isWindows) return;
    try {
      final file = await _file();
      if (!await file.exists()) return;
      final raw = jsonDecode(await file.readAsString());
      if (raw is! Map<String, dynamic>) return;
      final w = (raw['width'] as num).toDouble();
      final h = (raw['height'] as num).toDouble();
      final x = (raw['x'] as num).toDouble();
      final y = (raw['y'] as num).toDouble();
      if (![w, h, x, y].every((v) => v.isFinite) || w < 760 || h < 540 || w > 10000 || h > 10000) return;
      // 画面構成変更時にウィンドウが画面外へ消えないよう表示領域と交差を確認する。
      final displays = await windowManager.getBounds();
      // 保存値が著しく遠方の場合は標準配置に戻す。
      if ((x - displays.left).abs() > 10000 || (y - displays.top).abs() > 10000) return;
      await windowManager.setSize(Size(w, h));
      await windowManager.setPosition(Offset(x, y));
    } catch (_) { /* 設定破損時は既定のウィンドウ配置を使用 */ }
  }

  static Future<void> save() async {
    if (!Platform.isWindows) return;
    try {
      final bounds = await windowManager.getBounds();
      if (bounds.width < 760 || bounds.height < 540) return;
      final file = await _file();
      await file.writeAsString(jsonEncode({
        'x': bounds.left, 'y': bounds.top,
        'width': bounds.width, 'height': bounds.height,
      }), flush: true);
    } catch (_) { /* 配置情報の保存失敗は保管庫へ影響させない */ }
  }
}


// ===== データモデル =====

bool isPasswordName(String name) {
  final normalized = name.toLowerCase();
  return normalized.contains('password') ||
      normalized.contains('passwd') ||
      normalized.contains('パスワード') ||
      normalized.contains('暗証番号') ||
      normalized.contains('pinコード');
}


enum InformationType { generated, registered }
enum ClipboardProtection { all, sensitive, off }

const masterTemplates = <String>[
  '氏名', '氏名（カナ）', '姓', '名', 'メールアドレス', '電話番号',
  '郵便番号', '都道府県', '市区町村', '住所', '生年月日',
  'ユーザー名', 'パスワード',
];

// 仕様書 v0.3.0 第5章：登録確認状態と利用状況は別々に管理する。
// 既存の保存値（unconfirmed/confirmed, active/inactive/closed）は
// _restore() で読み替えるため、古い暗号化データを初期化する必要はない。
enum RegistrationStatus {
  candidate('候補'),
  unconfirmed('未確認'),
  confirmed('登録確認済み'),
  withdrawalConfirmed('退会確認済み');

  const RegistrationStatus(this.label);
  final String label;
}

enum UsageStatus {
  active('利用中'),
  paused('休止中'),
  ended('利用終了'),
  unknown('不明');

  const UsageStatus(this.label);
  final String label;
}

class InformationField {
  InformationField({
    required this.id,
    required this.name,
    required this.value,
    required this.type,
    bool? sensitive,
    this.createdAt,
    this.confirmedAt,
    this.disclosureSelected = false,
    List<FieldHistoryEntry>? history,
  }) : history = history ?? <FieldHistoryEntry>[],
       sensitive = sensitive ?? isPasswordName(name);

  final String id;
  String name;
  String value;
  final InformationType type;
  bool sensitive;
  // 旧データには存在しないため、null を許容する。
  final DateTime? createdAt;
  DateTime? confirmedAt;
  // 提供予定情報の明示選択。外部送信は行わない。
  bool disclosureSelected;
  final List<FieldHistoryEntry> history;
}

class FieldHistoryEntry {
  FieldHistoryEntry({required this.action, required this.at, required this.detail, this.retainedValue});
  final String action;
  final DateTime at;
  final String detail; // 操作内容。
  String? retainedValue;
  FieldHistoryEntry.withValue({required this.action, required this.at, required this.detail, this.retainedValue});
}

class Account {
  Account({
    required this.id,
    required this.name,
  });

  final String id;
  String name;
  RegistrationStatus registrationStatus =
      RegistrationStatus.unconfirmed;
  UsageStatus usageStatus = UsageStatus.active;
  final List<InformationField> fields = [];
}

class Service {
  Service({
    required this.id,
    required this.name,
    required this.url,
  });

  final String id;
  String name;
  String url;
  final List<Account> accounts = [];
}

// ===== STEP 5: 任意のマスター情報（初期版は1セット） =====
class MasterField {
  MasterField({
    required this.id,
    required this.name,
    required this.value,
    bool? sensitive,
  }) : sensitive = sensitive ?? isPasswordName(name);

  final String id;
  String name;
  String value;
  bool sensitive;
}

// ===== STEP 4: 生成候補情報（端末内で生成） =====
enum GeneratedValueKind { username, password, custom }
enum CandidateSource { random, master }
enum MasterTransform { unchanged, appendRandom, extract, extractAppendRandom, template }

class CandidateGenerator {
  static const _lower = 'abcdefghijklmnopqrstuvwxyz';
  static const _upper = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ';
  static const _digits = '0123456789';
  static const _symbols = '!@#\$%^&*()-_=+[]{}:,.?';
  static final Random _random = Random.secure();

  static String _pick(String characters) =>
      characters[_random.nextInt(characters.length)];

  static String generate({
    required GeneratedValueKind kind,
    required int length,
    String prefix = 'user_',
    bool lower = true,
    bool upper = true,
    bool digits = true,
    bool symbols = false,
  }) {
    if (length < 1 || length > 256) {
      throw ArgumentError('生成文字数は1～256文字にしてください。');
    }
    final sets = <String>[
      if (lower) _lower,
      if (upper) _upper,
      if (digits) _digits,
      if (symbols) _symbols,
    ];
    if (sets.isEmpty) throw ArgumentError('文字種を1つ以上選択してください。');
    if (length < sets.length) {
      throw ArgumentError('文字数は選択した文字種の数以上にしてください。');
    }

    // 選択した各文字種が最低1文字は含まれるようにする。
    final characters = sets.join();
    final result = <String>[
      for (final set in sets) _pick(set),
      for (var i = sets.length; i < length; i++) _pick(characters),
    ];
    // Fisher-Yatesで文字位置をランダム化する。
    for (var i = result.length - 1; i > 0; i--) {
      final j = _random.nextInt(i + 1);
      final temp = result[i];
      result[i] = result[j];
      result[j] = temp;
    }
    return kind == GeneratedValueKind.username
        ? '$prefix${result.join()}'
        : result.join();
  }
}

// STEP 6-2: マスター情報の部分抽出とテンプレート合成。
// テンプレート内の {master} は抽出後のマスター値、{random} はランダム部分。
class MasterCandidateComposer {
  static String extract(String value, int start, int count) {
    final chars = value.runes.toList();
    if (start < 0 || count < 1 || start >= chars.length || start + count > chars.length) {
      throw ArgumentError('抽出範囲が不正です。元の値は${chars.length}文字です。');
    }
    return String.fromCharCodes(chars.sublist(start, start + count));
  }

  static String compose({
    required MasterTransform transform,
    required String master,
    required String randomPart,
    required int start,
    required int count,
    required String template,
  }) {
    if (master.isEmpty) throw ArgumentError('マスター項目の値が空です。');
    final extracted = switch (transform) {
      MasterTransform.extract || MasterTransform.extractAppendRandom =>
        extract(master, start, count),
      _ => master,
    };
    return switch (transform) {
      MasterTransform.unchanged => master,
      MasterTransform.appendRandom => '$master$randomPart',
      MasterTransform.extract => extracted,
      MasterTransform.extractAppendRandom => '$extracted$randomPart',
      MasterTransform.template => _render(template, master, randomPart),
    };
  }

  static String _render(String template, String master, String randomPart) {
    if (template.isEmpty) throw ArgumentError('組み合わせ形式を入力してください。');
    if (!template.contains('{master}') && !template.contains('{random}')) {
      throw ArgumentError('形式には {master} または {random} を含めてください。');
    }
    final result = template.replaceAll('{master}', master).replaceAll('{random}', randomPart);
    if (result.isEmpty) throw ArgumentError('生成結果が空です。');
    return result;
  }
}

// ===== ローカル暗号化保存（Windows試作版） =====
class LocalVault {
  static const _storage = FlutterSecureStorage();
  static const _keyName = 'mycattles.vault.key.v1';
  static const _fileName = 'mycattles_vault_v1.enc';
  static final _cipher = AesGcm.with256bits();

  Future<File> _file() async {
    final directory = await getApplicationSupportDirectory();
    return File('${directory.path}${Platform.pathSeparator}$_fileName');
  }

  Future<SecretKey> _key({required bool create}) async {
    var encoded = await _storage.read(key: _keyName);
    if (encoded == null) {
      if (!create) {
        throw StateError('保存データの復号鍵が見つかりません。既存ファイルは変更しません。');
      }
      final random = Random.secure();
      final bytes = List<int>.generate(32, (_) => random.nextInt(256));
      encoded = base64Encode(bytes);
      await _storage.write(key: _keyName, value: encoded);
    }
    final bytes = base64Decode(encoded);
    if (bytes.length != 32) throw const FormatException('鍵の長さが不正です。');
    return SecretKey(bytes);
  }

  Future<Map<String, dynamic>?> load() async {
    final file = await _file();
    final backup = File('${file.path}.bak');
    final pendingBackup = File('${file.path}.bak.next');

    // 正式ファイルがない場合だけ、保存途中に退避したファイルを戻す。
    // 復旧候補が存在する場合、復号できなくても新規データ扱いにしない。
    if (!await file.exists()) {
      if (await pendingBackup.exists()) {
        await pendingBackup.rename(file.path);
      } else if (await backup.exists()) {
        await backup.rename(file.path);
      } else {
        return null;
      }
    }

    final key = await _key(create: false);
    final envelope =
        jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    if (envelope['format'] != 1) {
      throw const FormatException('未対応の保存形式です。');
    }
    final box = SecretBox(
      base64Decode(envelope['ciphertext'] as String),
      nonce: base64Decode(envelope['nonce'] as String),
      mac: Mac(base64Decode(envelope['mac'] as String)),
    );
    final clear = await _cipher.decrypt(box, secretKey: key);
    final data = jsonDecode(utf8.decode(clear));
    if (data is! Map<String, dynamic> || data['schemaVersion'] != 1) {
      throw const FormatException('未対応のデータ形式です。');
    }
    return data;
  }

  // 全初期化時は復旧候補を含めて削除し、最後に復号鍵を削除する。
  Future<void> resetAll() async {
    final file = await _file();
    for (final suffix in ['.bak.next', '.bak', '.tmp', '']) {
      final target = File('${file.path}$suffix');
      if (await target.exists()) await target.delete();
    }
    await _storage.delete(key: _keyName);
  }

  Future<void> save(Map<String, dynamic> data) async {
    final file = await _file();
    final key = await _key(create: true);
    final box =
        await _cipher.encrypt(utf8.encode(jsonEncode(data)), secretKey: key);
    final envelope = jsonEncode({
      'format': 1,
      'nonce': base64Encode(box.nonce),
      'ciphertext': base64Encode(box.cipherText),
      'mac': base64Encode(box.mac.bytes),
    });

    final temporary = File('${file.path}.tmp');
    final backup = File('${file.path}.bak');
    final pendingBackup = File('${file.path}.bak.next');

    // 既存ファイルには触れず、まず新しい暗号化データを書き切る。
    await temporary.writeAsString(envelope, flush: true);

    if (await file.exists()) {
      // 前回の保存が完了していれば、古い退避途中ファイルを整理できる。
      if (await pendingBackup.exists()) {
        await pendingBackup.delete();
      }
      // 旧バックアップを残したまま、現在の正式ファイルを別名に退避。
      await file.rename(pendingBackup.path);
      try {
        await temporary.rename(file.path);
      } catch (_) {
        // 通常のファイル操作失敗時には元の正式ファイルを戻す。
        if (!await file.exists() && await pendingBackup.exists()) {
          await pendingBackup.rename(file.path);
        }
        rethrow;
      }

      // 正式ファイルの更新が済んだ後でバックアップを更新する。
      // 整理に失敗しても正式ファイルは残る。
      if (await backup.exists()) await backup.delete();
      await pendingBackup.rename(backup.path);
    } else {
      // 初回保存。過去の復旧候補がある場合は上書きしない。
      if (await backup.exists() || await pendingBackup.exists()) {
        throw StateError('復旧候補が残っています。上書きを中止しました。');
      }
      await temporary.rename(file.path);
    }
  }

}

// 画面ロックの認証情報は暗号化データ本体と独立してOSの安全な領域に保持する。
// PINの保存・照合は端末内のみで行い、ネットワーク送信しない。
class AppLockStore {
  static const _storage = FlutterSecureStorage();
  static const _pinKey = 'mycattles.app_lock.pin.v1';
  static const _warningKey = 'mycattles.first_warning_seen.v1';

  Future<String?> readPin() => _storage.read(key: _pinKey);
  Future<void> setPin(String pin) => _storage.write(key: _pinKey, value: pin);
  Future<void> clearPin() => _storage.delete(key: _pinKey);
  Future<bool> warningSeen() async =>
      (await _storage.read(key: _warningKey)) == 'yes';
  Future<void> markWarningSeen() =>
      _storage.write(key: _warningKey, value: 'yes');
}

// ===== アプリ =====

class MyCattlesApp extends StatelessWidget {
  const MyCattlesApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: appTheme,
      builder: (context, mode, _) => MaterialApp(
      themeMode: mode,
      darkTheme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF6750A4), brightness: Brightness.dark), useMaterial3: true),
      title: 'MyCATTLES',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF6750A4),
        ),
        useMaterial3: true,
      ),
      home: const MainScreen(),
    ));
  }
}

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> with WindowListener {
  ThemeMode themeMode = ThemeMode.system;
  bool autoLockEnabled = false;
  int autoLockMinutes = 5;
  Timer? _idleTimer;
  Timer? _windowSaveTimer;
  bool _advancedDataOpen = false;

  void _resetIdleTimer() {
    _idleTimer?.cancel();
    if (_lockPin == null || !autoLockEnabled || _locked || _loading || _securityBusy) return;
    _idleTimer = Timer(Duration(minutes: autoLockMinutes), () {
      if (mounted && !_locked && !_securityBusy) {
        setState(() { _locked = true; _revealedFields.clear(); });
      }
    });
  }

  void _recordActivity() => _resetIdleTimer();
  void _onPointer(PointerEvent event) => _recordActivity();
  bool _onKeyboard(KeyEvent event) {
    if (event is KeyDownEvent || event is KeyRepeatEvent) _recordActivity();
    return false;
  }


  @override
  void onWindowMove() => _scheduleWindowSave();
  @override
  void onWindowResize() => _scheduleWindowSave();
  void _scheduleWindowSave() {
    _windowSaveTimer?.cancel();
    _windowSaveTimer = Timer(const Duration(milliseconds: 650), _WindowPlacement.save);
  }

  final List<Service> services = [];
  final List<MasterField> masterFields = [];
  bool masterCreated = false;
  // Phase 1は単一のデジタル人格。既存データは自動的にこの人格に属する。
  String personaName = '自分';
  bool hideMasterPrompt = false;
  bool warnOnUnprotect = true;
  bool retainHistoryValues = false;
  int _serviceExpansionEpoch = 0;
  ClipboardProtection clipboardProtection = ClipboardProtection.all;
  int clipboardSeconds = 30;
  final Set<String> _expandedCandidates = <String>{};
  String? _jumpServiceId;
  String? _jumpAccountId;
  int selectedIndex = 0;
  int nextId = 0;
  final Set<String> _revealedFields = <String>{};
  final TextEditingController _serviceSearchController = TextEditingController();
  String _serviceQuery = '';
  String _generatedQuery = '';
  final TextEditingController _generatedSearchController = TextEditingController();
  String _serviceSort = 'name';
  String _serviceUsageFilter = 'all';
  String _generatedFilter = 'all';
  Timer? _clipboardTimer;
  String? _lastCopiedValue;
  final AppLockStore _lockStore = AppLockStore();
  String? _lockPin;
  int _pinFailures = 0;
  DateTime? _pinRetryAt;

  bool get _pinRetryBlocked =>
      _pinRetryAt != null && DateTime.now().isBefore(_pinRetryAt!);

  bool _verifyPin(String candidate) {
    if (_pinRetryBlocked) {
      final seconds = _pinRetryAt!.difference(DateTime.now()).inSeconds + 1;
      setState(() => _securityError = 'PINの再試行は約$seconds秒後に可能です。');
      return false;
    }
    if (candidate == _lockPin) {
      _pinFailures = 0;
      _pinRetryAt = null;
      return true;
    }
    _pinFailures++;
    if (_pinFailures >= 5) {
      _pinFailures = 0;
      _pinRetryAt = DateTime.now().add(const Duration(seconds: 30));
      setState(() => _securityError = 'PINが一致しません。30秒後に再試行してください。');
    } else {
      setState(() => _securityError = 'PINが一致しません。');
    }
    return false;
  }

  bool _locked = false;
  bool _showFirstWarning = false;
  bool _securityBusy = false;
  String? _securityError;


  @override
  void dispose() {
    _clipboardTimer?.cancel();
    _idleTimer?.cancel();
    _windowSaveTimer?.cancel();
    HardwareKeyboard.instance.removeHandler(_onKeyboard);
    GestureBinding.instance.pointerRouter.removeGlobalRoute(_onPointer);
    if (Platform.isWindows) { windowManager.removeListener(this); _WindowPlacement.save(); }
    _serviceSearchController.dispose();
    _generatedSearchController.dispose();
    super.dispose();
  }

  Future<void> _copyProtected(String value, {bool sensitive = true}) async {
    _clipboardTimer?.cancel();
    _lastCopiedValue = value;
    await Clipboard.setData(ClipboardData(text: value));
    final protect = clipboardProtection == ClipboardProtection.all ||
        (clipboardProtection == ClipboardProtection.sensitive && sensitive);
    if (!protect) return;
    _clipboardTimer = Timer(Duration(seconds: clipboardSeconds), () async {
      if (_lastCopiedValue != value) return;
      try {
        final current = await Clipboard.getData(Clipboard.kTextPlain);
        if (_lastCopiedValue == value && current?.text == value) {
          await Clipboard.setData(const ClipboardData(text: ''));
        }
      } catch (_) {
        // OSがクリップボードを占有している場合は変更しない。
      } finally {
        if (_lastCopiedValue == value) _lastCopiedValue = null;
      }
    });
  }

  String createId() => (++nextId).toString();

  final LocalVault _vault = LocalVault();
  Future<void> _saveChain = Future<void>.value();
  bool _loading = true;
  bool _storageFailed = false;
  String? _storageMessage;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKeyboard);
    GestureBinding.instance.pointerRouter.addGlobalRoute(_onPointer);
    if (Platform.isWindows) windowManager.addListener(this);
    _loadData();
  }

  Map<String, dynamic> _snapshot() => {
    'schemaVersion': 1,
    'nextId': nextId,
    'persona': {'id': 'primary', 'name': personaName},
    'preferences': {
      'hideMasterPrompt': hideMasterPrompt,
      'warnOnUnprotect': warnOnUnprotect,
      'retainHistoryValues': retainHistoryValues,
      'clipboardProtection': clipboardProtection.name,
      'clipboardSeconds': clipboardSeconds,
      'themeMode': themeMode.name,
      'autoLockEnabled': autoLockEnabled,
      'autoLockMinutes': autoLockMinutes,
    },
    'master': masterCreated
        ? {
            'fields': masterFields.map((field) => {
              'id': field.id,
              'name': field.name,
              'value': field.value,
              'sensitive': field.sensitive,
            }).toList(),
          }
        : null,
    'services': services.map((service) => {
      'id': service.id,
      'name': service.name,
      'url': service.url,
      'accounts': service.accounts.map((account) => {
        'id': account.id,
        'name': account.name,
        'registrationStatus': account.registrationStatus.name,
        'usageStatus': account.usageStatus.name,
        'fields': account.fields.map((field) => {
          'id': field.id,
          'name': field.name,
          'value': field.value,
          'type': field.type.name,
          'sensitive': field.sensitive,
          'createdAt': field.createdAt?.toIso8601String(),
          'confirmedAt': field.confirmedAt?.toIso8601String(),
          'disclosureSelected': field.disclosureSelected,
          'history': field.history.map((event) => {
            'action': event.action,
            'at': event.at.toIso8601String(),
            'detail': event.detail,
             if (event.retainedValue != null) 'retainedValue': event.retainedValue,
          }).toList(),
        }).toList(),
      }).toList(),
    }).toList(),
  };

  void _restore(Map<String, dynamic> data) {
    final loaded = <Service>[];
    for (final rawService in data['services'] as List<dynamic>) {
      final entry = rawService as Map<String, dynamic>;
      final service = Service(
        id: entry['id'] as String,
        name: entry['name'] as String,
        url: entry['url'] as String,
      );
      for (final rawAccount in entry['accounts'] as List<dynamic>) {
        final a = rawAccount as Map<String, dynamic>;
        final account = Account(id: a['id'] as String, name: a['name'] as String);
        // 旧版の「退会済み」は利用状況に混在していたため、
        // 退会確認済み＋利用終了として移行する。
        // 「利用停止」は休止中へ読み替える。元データは復号後のメモリ上で
        // 読み替えるだけで、次回の編集保存までは書き換えない。
        final oldRegistration = a['registrationStatus'] as String;
        final oldUsage = a['usageStatus'] as String;
        account.registrationStatus = oldUsage == 'closed'
            ? RegistrationStatus.withdrawalConfirmed
            : RegistrationStatus.values.byName(oldRegistration);
        account.usageStatus = switch (oldUsage) {
          'inactive' => UsageStatus.paused,
          'closed' => UsageStatus.ended,
          _ => UsageStatus.values.byName(oldUsage),
        };
        for (final rawField in a['fields'] as List<dynamic>) {
          final f = rawField as Map<String, dynamic>;
          account.fields.add(InformationField(
            id: f['id'] as String,
            name: f['name'] as String,
            value: f['value'] as String,
            type: InformationType.values.byName(f['type'] as String),
            sensitive: f['sensitive'] is bool ? f['sensitive'] as bool : null,
            createdAt: DateTime.tryParse(f['createdAt'] as String? ?? ''),
            confirmedAt: DateTime.tryParse(f['confirmedAt'] as String? ?? ''),
            disclosureSelected: f['disclosureSelected'] == true,
            history: (f['history'] as List<dynamic>? ?? []).map((raw) {
              final item = raw as Map<String, dynamic>;
              return FieldHistoryEntry(
                action: item['action'] as String? ?? '不明',
                at: DateTime.tryParse(item['at'] as String? ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0),
                detail: item['detail'] as String? ?? '',
                 retainedValue: item['retainedValue'] as String?,
              );
            }).toList(),
          ));
        }
        service.accounts.add(account);
      }
      loaded.add(service);
    }
    // 旧データに master が存在しない場合は未作成として読み込む。
    final rawMaster = data['master'];
    final loadedMaster = <MasterField>[];
    if (rawMaster != null) {
      final master = rawMaster as Map<String, dynamic>;
      for (final rawField in master['fields'] as List<dynamic>) {
        final f = rawField as Map<String, dynamic>;
        loadedMaster.add(MasterField(
          id: f['id'] as String,
          name: f['name'] as String,
          value: f['value'] as String,
          sensitive: f['sensitive'] is bool ? f['sensitive'] as bool : null,
        ));
      }
    }
    masterFields..clear()..addAll(loadedMaster);
    masterCreated = rawMaster != null;
    services..clear()..addAll(loaded);
    nextId = data['nextId'] as int;
    final preferences = data['preferences'];
    if (preferences is Map) {
      hideMasterPrompt = preferences['hideMasterPrompt'] == true;
       warnOnUnprotect = preferences['warnOnUnprotect'] != false;
       retainHistoryValues = preferences['retainHistoryValues'] == true;
      clipboardProtection = ClipboardProtection.values.firstWhere(
        (mode) => mode.name == preferences['clipboardProtection'],
        orElse: () => ClipboardProtection.all,
      );
      final mode = preferences['themeMode'];
      themeMode = ThemeMode.values.firstWhere((v) => v.name == mode,
          orElse: () => ThemeMode.system);
      appTheme.value = themeMode;
      autoLockEnabled = preferences['autoLockEnabled'] == true;
      final idle = preferences['autoLockMinutes'];
      if (idle is int && const [1, 5, 10, 15, 30].contains(idle)) autoLockMinutes = idle;
      final seconds = preferences['clipboardSeconds'];
      if (seconds is int && seconds >= 1 && seconds <= 3600) clipboardSeconds = seconds;
    }
    final persona = data['persona'];
    personaName = persona is Map && persona['name'] is String
        ? persona['name'] as String : '自分';
  }

  Future<void> _loadData() async {
    try {
      // ロック状態の読み取りに失敗した場合も画面を開放しない。
      final pin = await _lockStore.readPin();
      final warningSeen = await _lockStore.warningSeen();
      final data = await _vault.load();
      if (!mounted) return;
      setState(() {
        if (data != null) _restore(data);
        _lockPin = pin;
        _locked = pin != null;
        _showFirstWarning = !warningSeen;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _storageFailed = true;
        _storageMessage = '起動時の安全確認またはデータ復元に失敗しました。\n編集・保存を停止しています。\n$error';
      });
    }
  }

  void _changeData(VoidCallback change) {
    if (_loading || _storageFailed || _securityBusy || _locked || _showFirstWarning) return;
    setState(change);
    // 編集直後に内容を確定し、書き込み順序を直列化する。
    final snapshot = _snapshot();
    _saveChain = _saveChain.then((_) {
      if (_storageFailed) return Future<void>.value();
      return _vault.save(snapshot);
    }).catchError((Object error) {
      if (!mounted) return;
      setState(() {
        _storageFailed = true;
        _storageMessage = '保存に失敗しました。以後の編集を停止しています。\n$error';
      });
    });
  }



  Future<String?> _askPin({required String title, bool repeat = false}) async {
    final first = TextEditingController();
    final second = TextEditingController();
    String? error;
    ModalRoute<dynamic>? dialogRoute;
    try {
      return await showDialog<String>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) {
          dialogRoute = ModalRoute.of(dialogContext);
          return StatefulBuilder(
          builder: (dialogContext, refresh) => AlertDialog(
            title: Text(title),
            content: SizedBox(
              width: 360,
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                TextField(
                  controller: first,
                  obscureText: true,
                  autofocus: true,
                  keyboardType: TextInputType.number,
                  maxLength: 12,
                  decoration: const InputDecoration(labelText: 'PIN（6～12桁の数字）'),
                  onSubmitted: (_) {},
                ),
                if (repeat) TextField(
                  controller: second,
                  obscureText: true,
                  keyboardType: TextInputType.number,
                  maxLength: 12,
                  decoration: const InputDecoration(labelText: 'PIN（確認用）'),
                ),
                if (error != null) Text(error!,
                    style: TextStyle(color: Theme.of(dialogContext).colorScheme.error)),
              ]),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(dialogContext),
                  child: const Text('キャンセル')),
              FilledButton(
                onPressed: () {
                  final value = first.text;
                  if (!RegExp(r'^\d{6,12}$').hasMatch(value)) {
                    refresh(() => error = '6～12桁の数字を入力してください。');
                    return;
                  }
                  if (repeat && value != second.text) {
                    refresh(() => error = '確認用PINが一致しません。');
                    return;
                  }
                  Navigator.pop(dialogContext, value);
                },
                child: const Text('確認'),
              ),
            ],
          ),
        );
        },
      );
    } finally {
      // ダイアログの終了アニメーション中のTextFieldから参照されないようにする。
      if (dialogRoute != null) await dialogRoute!.completed;
      first.dispose();
      second.dispose();
    }
  }

  Future<void> _unlock() async {
    final pin = await _askPin(title: 'MyCATTLESのロックを解除');
    if (pin == null || !mounted) return;
    if (_verifyPin(pin)) {
      setState(() {
        _locked = false;
        _securityError = null;
      });
      _resetIdleTimer();
    }
  }

  Future<void> _enableLock() async {
    final pin = await _askPin(title: 'アプリロックを有効化', repeat: true);
    if (pin == null || !mounted) return;
    setState(() => _securityBusy = true);
    try {
      await _lockStore.setPin(pin);
      if (!mounted) return;
      setState(() => _lockPin = pin);
    } catch (error) {
      if (mounted) setState(() => _securityError = 'ロック設定の保存に失敗しました：$error');
    } finally {
      if (mounted) setState(() => _securityBusy = false);
    }
  }

  Future<void> _disableLock() async {
    final pin = await _askPin(title: 'ロック解除設定の確認');
    if (pin == null || !mounted) return;
    if (!_verifyPin(pin)) return;
    setState(() => _securityBusy = true);
    try {
      await _lockStore.clearPin();
      if (mounted) { setState(() => _lockPin = null); _idleTimer?.cancel(); }
    } catch (error) {
      if (mounted) setState(() => _securityError = 'ロック解除設定に失敗しました：$error');
    } finally {
      if (mounted) setState(() => _securityBusy = false);
    }
  }

  Future<void> _acknowledgeFirstWarning() async {
    setState(() => _securityBusy = true);
    try {
      await _lockStore.markWarningSeen();
      if (mounted) setState(() => _showFirstWarning = false);
    } catch (error) {
      if (mounted) setState(() => _securityError = '確認状態を保存できません：$error');
    } finally {
      if (mounted) setState(() => _securityBusy = false);
    }
  }

  Future<void> _withdrawAccount(Account account) async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('退会確認済みに変更'),
        content: Text('「${account.name}」を退会確認済み・利用終了として記録します。\n'
            '保存済みの認証情報・登録情報・生成候補は削除せず保持します。\n'
            '実際のWebサービスへの退会手続きは行いません。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('キャンセル')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('記録して保持')),
        ],
      ),
    ) ?? false;
    if (!accepted || !mounted) return;
    _changeData(() {
      account.registrationStatus = RegistrationStatus.withdrawalConfirmed;
      account.usageStatus = UsageStatus.ended;
    });
  }

  Future<void> _deleteAccountPermanently(Service service, Account account) async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('アカウント情報を削除'),
        content: Text('対象：${service.name} / ${account.name}\n'
            '登録情報・生成候補・パスワードを含む${account.fields.length}項目を削除します。\n'
            '削除後は画面から復元できません。ただし保存ファイルのバックアップや'
            'OSの記憶領域からの物理的な完全消去は保証できません。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('キャンセル')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('削除する')),
        ],
      ),
    ) ?? false;
    if (!accepted || !mounted) return;
    _changeData(() {
      for (final field in account.fields) {
        _revealedFields.remove(field.id);
      }
      service.accounts.remove(account);
    });
  }

  Future<void> _resetAllData() async {
    final controller = TextEditingController();
    bool accepted = false;
    try {
      accepted = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
          builder: (dialogContext, refresh) => AlertDialog(
            title: const Text('全データ初期化（取り消せません）'),
            content: SizedBox(width: 420, child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('登録サービス${services.length}件、アカウント$accountCount件、'
                    'マスター情報${masterFields.length}項目、および全認証情報を削除します。'),
                const SizedBox(height: 8),
                const Text('暗号化保存ファイル・アプリ管理の復旧候補・復号鍵を削除します。'
                    'OSのバックアップや記憶媒体からの物理的な完全消去は保証できません。'),
                const SizedBox(height: 12),
                TextField(
                  controller: controller,
                  decoration: const InputDecoration(labelText: '確認のため「初期化」と入力'),
                  onChanged: (_) => refresh(() {}),
                ),
              ],
            )),
            actions: [
              TextButton(onPressed: () => Navigator.pop(dialogContext, false),
                  child: const Text('キャンセル')),
              FilledButton(
                onPressed: controller.text == '初期化'
                    ? () => Navigator.pop(dialogContext, true) : null,
                child: const Text('全データを削除'),
              ),
            ],
          ),
        ),
      ) ?? false;
    } finally {
      WidgetsBinding.instance.addPostFrameCallback((_) => controller.dispose());
    }
    if (!accepted || !mounted) return;
    setState(() => _securityBusy = true);
    try {
      // 保存キューが完了してから削除し、古い保存処理による再生成を防止する。
      await _saveChain;
      await _vault.resetAll();
      if (!mounted) return;
      setState(() {
        services.clear();
        masterFields.clear();
        masterCreated = false;
        nextId = 0;
        personaName = '自分';
        hideMasterPrompt = false;
         warnOnUnprotect = true;
         retainHistoryValues = false;
         clipboardProtection = ClipboardProtection.all;
        clipboardSeconds = 30;
        _expandedCandidates.clear();
        _jumpServiceId = null;
        _jumpAccountId = null;
        _revealedFields.clear();
        selectedIndex = 0;
        _serviceQuery = '';
        _generatedQuery = '';
        _serviceSearchController.clear();
        _generatedSearchController.clear();
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _storageFailed = true;
          _storageMessage = '全データ初期化に失敗しました。安全のため操作を停止します。\n$error';
        });
      }
    } finally {
      if (mounted) setState(() => _securityBusy = false);
    }
  }

  final titles = const [
    'ホーム',
    '登録サービス',
    '生成情報',
    'マスター情報',
    '設定',
    '提供情報',
  ];

  final icons = const [
    Icons.home_outlined,
    Icons.language,
    Icons.auto_awesome_outlined,
    Icons.person_outline,
    Icons.settings_outlined,
    Icons.fact_check_outlined,
  ];

  int get accountCount =>
      services.fold(0, (sum, service) => sum + service.accounts.length);

  int get generatedCount => services.fold(
        0,
        (sum, service) =>
            sum +
            service.accounts.fold(
              0,
              (accountSum, account) =>
                  accountSum +
                  account.fields
                      .where((f) => f.type == InformationType.generated)
                      .length,
            ),
      );


  Future<List<String>?> editTextDialog(
    String title,
    List<String> labels, {
    List<String>? initialValues,
    Set<int> protectedIndexes = const {},
  }) async {
    final controllers = List.generate(labels.length,
        (i) => TextEditingController(text: initialValues != null ? initialValues[i] : ''));
    final visible = <int>{};
    Future<void>? dialogRouteCompleted;
    try {
      return await showDialog<List<String>>(
        context: context,
        builder: (dialogContext) {
          dialogRouteCompleted ??= ModalRoute.of(dialogContext)?.completed;
          return StatefulBuilder(
          builder: (dialogContext, refresh) => AlertDialog(
            title: Text(title),
            content: SizedBox(
              width: 420,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: List.generate(labels.length, (i) => Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: TextField(
                    controller: controllers[i],
                    textInputAction: labels.length == 1 ? TextInputAction.done : TextInputAction.next,
                    onSubmitted: labels.length == 1 ? (_) {
                      final value = controllers[0].text.trim();
                      if (value.isNotEmpty) Navigator.pop(dialogContext, <String>[value]);
                    } : null,
                    obscureText: protectedIndexes.contains(i) && !visible.contains(i),
                    decoration: InputDecoration(
                      labelText: labels[i],
                      border: const OutlineInputBorder(),
                      suffixIcon: protectedIndexes.contains(i) ? IconButton(
                        tooltip: visible.contains(i) ? '値を隠す' : '値を表示',
                        icon: Icon(visible.contains(i)
                            ? Icons.visibility_off_outlined : Icons.visibility_outlined),
                        onPressed: () => refresh(() {
                          if (!visible.remove(i)) visible.add(i);
                        }),
                      ) : null,
                    ),
                  ),
                )),
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(dialogContext),
                  child: const Text('キャンセル')),
              FilledButton(
                onPressed: () {
                  final values = List<String>.generate(controllers.length,
                      (i) => i == 0 ? controllers[i].text.trim() : controllers[i].text);
                  if (values.first.isEmpty) return;
                  Navigator.pop(dialogContext, values);
                },
                child: const Text('保存'),
              ),
            ],
          ),
        );
        },
      );
    } finally {
      // showDialog completes when pop is requested, before the exit animation
      // unmounts its TextFields. Wait for the route to finish before disposal.
      if (dialogRouteCompleted != null) {
        await dialogRouteCompleted;
      }
      for (final controller in controllers) {
        controller.dispose();
      }
    }
  }

  Future<bool> confirmDelete(String name) async {
    return await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('削除の確認'),
            content: Text('「$name」を削除しますか？'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('キャンセル'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('削除'),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<void> addService() async {
    final values = await editTextDialog(
      'サービスを登録',
      ['サービス名', 'URL（任意）'],
    );

    if (values == null || !mounted) return;

    _changeData(() {
      services.add(
        Service(
          id: createId(),
          name: values[0],
          url: values[1],
        ),
      );
    });
  }

  Future<void> editService(Service service) async {
    final values = await editTextDialog(
      'サービスを編集',
      ['サービス名', 'URL（任意）'],
      initialValues: [service.name, service.url],
    );

    if (values == null || !mounted) return;

    _changeData(() {
      service.name = values[0];
      service.url = values[1];
    });
  }

  Future<void> addAccount(Service service) async {
    final controller = TextEditingController();
    final selected = <String>{};
    bool importMaster = false;
     InformationType importType = InformationType.registered;
    try {
      final accepted = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
          builder: (dialogContext, refresh) => AlertDialog(
            title: const Text('アカウントを追加'),
            content: SizedBox(width: 460, child: SingleChildScrollView(child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(controller: controller, autofocus: true,
                    decoration: const InputDecoration(labelText: 'アカウントの表示名')),
                if (masterCreated && masterFields.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('マスター情報から項目を一括コピー'),
                    subtitle: const Text('選択した値を登録情報としてコピーします。元のマスター情報は変更されません。'),
                    value: importMaster,
                    onChanged: (v) => refresh(() {
                      importMaster = v ?? false;
                      if (importMaster && selected.isEmpty) {
                        selected.addAll(masterFields.map((f) => f.id));
                      }
                    }),
                  ),
                  if (importMaster) ...[
                     DropdownButtonFormField<InformationType>(
                       initialValue: importType,
                       decoration: const InputDecoration(labelText: 'コピー先'),
                       items: const [
                         DropdownMenuItem(value: InformationType.registered, child: Text('登録情報（未確認）')),
                         DropdownMenuItem(value: InformationType.generated, child: Text('生成候補')),
                       ],
                       onChanged: (value) => refresh(() => importType = value ?? InformationType.registered),
                     ),
                     for (final field in masterFields)
                      CheckboxListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: Text(field.name),
                        subtitle: Text(field.sensitive ? '機密情報（値は非表示）' : '値をコピー'),
                        value: selected.contains(field.id),
                        onChanged: (v) => refresh(() {
                          if (v == true) { selected.add(field.id); }
                          else { selected.remove(field.id); }
                                                }),
                      ),
                     ],
                ],
              ],
            ))),
            actions: [
              TextButton(onPressed: () => Navigator.pop(dialogContext, false),
                  child: const Text('キャンセル')),
              FilledButton(onPressed: () {
                if (controller.text.trim().isEmpty) return;
                Navigator.pop(dialogContext, true);
              }, child: const Text('追加')),
            ],
          ),
        ),
      ) ?? false;
      if (!accepted || !mounted) return;
      _changeData(() {
        final account = Account(id: createId(), name: controller.text.trim());
        if (importMaster) {
          for (final master in masterFields.where((f) => selected.contains(f.id))) {
            account.fields.add(InformationField(
              id: createId(), name: master.name, value: master.value,
              type: importType, sensitive: master.sensitive,
               createdAt: importType == InformationType.generated ? DateTime.now() : null,
              history: [FieldHistoryEntry(action: 'マスター情報からコピー',
                at: DateTime.now(),
                detail: '登録確認は未実施。コピー元はマスター情報。',
                 retainedValue: retainHistoryValues ? master.value : null)],
            ));
          }
        }
        service.accounts.add(account);
      });
    } finally {
      WidgetsBinding.instance.addPostFrameCallback((_) => controller.dispose());
    }
  }

  Future<void> editAccount(Account account) async {
    final values = await editTextDialog(
      'アカウント名を編集',
      ['アカウントの表示名'],
      initialValues: [account.name],
    );

    if (values == null || !mounted) return;

    _changeData(() => account.name = values[0]);
  }

  Future<void> addField(
    Account account,
    InformationType type,
  ) async {
    final values = await editTextDialog(
      type == InformationType.generated
          ? '生成候補情報を追加'
          : '登録済み情報を追加',
      ['項目名', '値'],
      protectedIndexes: const {1},
    );

    if (values == null || !mounted) return;

    _changeData(() {
      account.fields.add(
        InformationField(
          id: createId(),
          name: values[0],
          value: values[1],
          type: type,
          createdAt: type == InformationType.generated ? DateTime.now() : null,
          history: [FieldHistoryEntry(action: '手動追加', at: DateTime.now(),
              detail: '値は履歴に保存しません。')],
        ),
      );
    });
  }

  Future<void> generateCandidate({
    Service? initialService,
    Account? initialAccount,
   }) async {
    if (services.every((service) => service.accounts.isEmpty)) {
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('生成先がありません'),
          content: const Text('先に登録サービスとアカウントを追加してください。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('閉じる'),
            ),
          ],
        ),
      );
      return;
    }

    Service selectedService = initialService ??
        services.firstWhere((service) => service.accounts.isNotEmpty);
    Account selectedAccount = initialAccount ?? selectedService.accounts.first;
    GeneratedValueKind kind = GeneratedValueKind.password;
    int length = 20;
    bool lower = true;
    bool upper = true;
    bool digits = true;
    bool symbols = true;
    final prefixController = TextEditingController(text: 'user_');
    final nameController = TextEditingController(text: 'パスワード');
    final templateController = TextEditingController(text: '{master}_{random}');
    final extractStartController = TextEditingController(text: '0');
    final extractCountController = TextEditingController(text: '3');
    String? error;
    String? preview;
    bool previewVisible = false;
    bool previewSensitive = true;
    CandidateSource source = CandidateSource.random;
    MasterTransform masterTransform = MasterTransform.unchanged;
    MasterField? selectedMaster = masterCreated && masterFields.isNotEmpty
        ? masterFields.first : null;

    try {
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
          builder: (dialogContext, refresh) {
            final username = kind == GeneratedValueKind.username;
            return AlertDialog(
              title: const Text('生成候補情報を作成'),
              content: SizedBox(
                width: 500,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      DropdownButtonFormField<Service>(
                        key: ValueKey('service_${selectedService.id}'),
                        initialValue: selectedService,
                        decoration: const InputDecoration(labelText: '登録サービス'),
                        items: [
                          for (final service in services)
                            if (service.accounts.isNotEmpty)
                              DropdownMenuItem(value: service, child: Text(service.name)),
                        ],
                        onChanged: initialService != null ? null : (value) {
                           if (value == null) return;
                           refresh(() {
                             selectedService = value;
                            selectedAccount = value.accounts.first;
                            preview = null;
                          });
                        },
                      ),
                      const SizedBox(height: 12),
                      DropdownButtonFormField<Account>(
                        key: ValueKey('account_${selectedService.id}_${selectedAccount.id}'),
                        initialValue: selectedAccount,
                        decoration: const InputDecoration(labelText: 'アカウント'),
                        items: [
                          for (final account in selectedService.accounts)
                            DropdownMenuItem(value: account, child: Text(account.name)),
                        ],
                        onChanged: initialAccount != null ? null : (value) {
                           if (value != null) refresh(() { selectedAccount = value; preview = null; });
                        },
                      ),
                      const SizedBox(height: 12),
                      DropdownButtonFormField<CandidateSource>(
                        key: ValueKey('source_${source.name}'),
                        initialValue: source,
                        decoration: const InputDecoration(labelText: '候補の作成方法'),
                        items: [
                          const DropdownMenuItem(value: CandidateSource.random,
                              child: Text('ランダム生成')),
                          if (masterCreated && masterFields.isNotEmpty)
                            const DropdownMenuItem(value: CandidateSource.master,
                                child: Text('マスター情報を利用')),
                        ],
                        onChanged: (value) {
                          if (value == null) return;
                          refresh(() {
                            source = value;
                            preview = null;
                            error = null;
                            nameController.text = source == CandidateSource.master
                                ? (selectedMaster?.name ?? 'マスター由来情報')
                                : 'パスワード';
                          });
                        },
                      ),
                      if (source == CandidateSource.master) ...[
                        const SizedBox(height: 12),
                        DropdownButtonFormField<MasterField>(
                          initialValue: selectedMaster,
                          decoration: const InputDecoration(labelText: '参照するマスター項目'),
                          items: [
                            for (final field in masterFields)
                              DropdownMenuItem(value: field, child: Text(field.name)),
                          ],
                          onChanged: (value) {
                            refresh(() {
                              selectedMaster = value;
                              nameController.text = value?.name ?? '';
                              preview = null;
                            });
                          },
                        ),
                        const SizedBox(height: 12),
                        DropdownButtonFormField<MasterTransform>(
                          initialValue: masterTransform,
                          decoration: const InputDecoration(labelText: '変換方法'),
                          items: const [
                            DropdownMenuItem(value: MasterTransform.unchanged,
                                child: Text('そのまま使用（無変換）')),
                            DropdownMenuItem(value: MasterTransform.appendRandom,
                                child: Text('元の値の末尾にランダム文字列を付加')),
                            DropdownMenuItem(value: MasterTransform.extract,
                                child: Text('一部分だけ抽出')),
                            DropdownMenuItem(value: MasterTransform.extractAppendRandom,
                                child: Text('一部分を抽出してランダム文字列を付加')),
                            DropdownMenuItem(value: MasterTransform.template,
                                child: Text('自由な組み合わせ（テンプレート）')),
                          ],
                          onChanged: (value) {
                            if (value != null) {
                              refresh(() {
                                masterTransform = value;
                                preview = null;
                              });
                            }
                          },
                        ),
                        const SizedBox(height: 8),
                        if (masterTransform == MasterTransform.extract ||
                             masterTransform == MasterTransform.extractAppendRandom) ...[
                           const SizedBox(height: 8),
                           Text('抽出元の文字数：${selectedMaster?.value.runes.length ?? 0}'),
                           Row(children: [
                             Expanded(child: TextField(
                               controller: extractStartController,
                               keyboardType: TextInputType.number,
                               decoration: const InputDecoration(labelText: '開始位置（0から）'),
                               onChanged: (_) => refresh(() { preview = null; error = null; }),
                             )),
                             const SizedBox(width: 12),
                             Expanded(child: TextField(
                               controller: extractCountController,
                               keyboardType: TextInputType.number,
                               decoration: const InputDecoration(labelText: '抽出文字数'),
                               onChanged: (_) => refresh(() { preview = null; error = null; }),
                             )),
                           ]),
                         ],
                         if (masterTransform == MasterTransform.template) ...[
                           const SizedBox(height: 8),
                           TextField(
                             controller: templateController,
                             decoration: const InputDecoration(
                               labelText: '組み合わせ形式',
                               helperText: '{master}=元の値、{random}=ランダム文字列。固定文字も入力可',
                             ),
                             onChanged: (_) => refresh(() { preview = null; error = null; }),
                           ),
                         ],
                         const Text('元のマスター情報は変更されません。'),
                      ],
                      if (source == CandidateSource.random)
                      DropdownButtonFormField<GeneratedValueKind>(
                        initialValue: kind,
                        decoration: const InputDecoration(labelText: '生成する情報'),
                        items: const [
                          DropdownMenuItem(value: GeneratedValueKind.username, child: Text('ユーザー名')),
                          DropdownMenuItem(value: GeneratedValueKind.password, child: Text('パスワード')),
                          DropdownMenuItem(value: GeneratedValueKind.custom, child: Text('任意文字列')),
                        ],
                        onChanged: (value) {
                          if (value == null) return;
                          refresh(() {
                            kind = value;
                            length = value == GeneratedValueKind.username ? 12 : 20;
                            symbols = value == GeneratedValueKind.password;
                            nameController.text = switch (value) {
                              GeneratedValueKind.username => 'ユーザー名',
                              GeneratedValueKind.password => 'パスワード',
                              GeneratedValueKind.custom => '任意文字列',
                            };
                            preview = null;
                            error = null;
                          });
                        },
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: nameController,
                        decoration: const InputDecoration(labelText: '保存する項目名'),
                      ),
                      if (source == CandidateSource.random && username) ...[
                        const SizedBox(height: 12),
                        TextField(
                          controller: prefixController,
                          decoration: const InputDecoration(labelText: '接頭辞（任意）'),
                        ),
                      ],
                      if (source == CandidateSource.random ||
                          masterTransform == MasterTransform.appendRandom ||
                           masterTransform == MasterTransform.extractAppendRandom ||
                           (masterTransform == MasterTransform.template &&
                               templateController.text.contains('{random}'))) ...[
                      const SizedBox(height: 12),
                      Text('ランダム部分の文字数：$length'),
                      Slider(
                        value: length.toDouble(),
                        min: 4,
                        max: 64,
                        divisions: 60,
                        label: '$length',
                        onChanged: (value) => refresh(() { length = value.round(); preview = null; }),
                      ),
                      Wrap(
                        spacing: 12,
                        children: [
                          FilterChip(label: const Text('英小文字'), selected: lower,
                            onSelected: (v) => refresh(() { lower = v; preview = null; })),
                          FilterChip(label: const Text('英大文字'), selected: upper,
                            onSelected: (v) => refresh(() { upper = v; preview = null; })),
                          FilterChip(label: const Text('数字'), selected: digits,
                            onSelected: (v) => refresh(() { digits = v; preview = null; })),
                          FilterChip(label: const Text('記号'), selected: symbols,
                            onSelected: (v) => refresh(() { symbols = v; preview = null; })),
                        ],
                      ),
                      ],
                      const SizedBox(height: 12),
                      OutlinedButton.icon(
                        onPressed: () {
                          try {
                            final master = selectedMaster;
                            if (source == CandidateSource.master && master == null) {
                              throw StateError('マスター項目を選択してください。');
                            }
                            if (source == CandidateSource.master && master!.value.isEmpty) {
                              throw StateError('マスター項目の値が空です。');
                            }
                            final needsRandom = source == CandidateSource.random ||
                                 (source == CandidateSource.master &&
                                     (masterTransform == MasterTransform.appendRandom ||
                                      masterTransform == MasterTransform.extractAppendRandom ||
                                      (masterTransform == MasterTransform.template &&
                                          templateController.text.contains('{random}'))));
                             final randomPart = needsRandom
                                 ? CandidateGenerator.generate(
                                     kind: source == CandidateSource.random
                                         ? kind : GeneratedValueKind.custom,
                                     length: length,
                                     prefix: prefixController.text,
                                     lower: lower, upper: upper,
                                     digits: digits, symbols: symbols,
                                   )
                                 : '';
                             final value = source == CandidateSource.random
                                 ? randomPart
                                 : MasterCandidateComposer.compose(
                                     transform: masterTransform,
                                     master: master!.value,
                                     randomPart: randomPart,
                                     start: int.tryParse(extractStartController.text) ?? -1,
                                     count: int.tryParse(extractCountController.text) ?? -1,
                                     template: templateController.text,
                                   );
                            refresh(() {
                              preview = value;
                              previewVisible = false;
                              previewSensitive = source == CandidateSource.master
                                  ? (master!.sensitive || isPasswordName(nameController.text))
                                  : kind == GeneratedValueKind.password ||
                                      isPasswordName(nameController.text);
                              error = null;
                            });
                          } catch (e) {
                            refresh(() { preview = null; error = '$e'; });
                          }
                        },
                        icon: const Icon(Icons.refresh),
                        label: Text(preview == null ? '生成する' : '再生成する'),
                      ),
                      if (preview != null) ...[
                        const SizedBox(height: 8),
                        Row(
                           children: [
                             Expanded(child: SelectableText(
                               previewSensitive && !previewVisible
                                   ? '••••••••••••' : preview!,
                               style: const TextStyle(fontFamily: 'monospace'),
                             )),
                             if (previewSensitive)
                               IconButton(
                                 tooltip: previewVisible ? '隠す' : '表示する',
                                 onPressed: () => refresh(() => previewVisible = !previewVisible),
                                 icon: Icon(previewVisible ? Icons.visibility_off : Icons.visibility),
                               ),
                             IconButton(
                               tooltip: 'コピー',
                               onPressed: () => _copyProtected(preview!, sensitive: previewSensitive),
                               icon: const Icon(Icons.copy_outlined),
                             ),
                           ],
                         ),
                      ],
                      if (error != null) ...[
                        const SizedBox(height: 8),
                        Text(error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                      ],
                      const SizedBox(height: 8),
                      const Text('保存しても登録済み情報には反映されません。'),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('キャンセル')),
                FilledButton(
                  onPressed: preview == null ? null : () {
                    final name = nameController.text.trim();
                    if (name.isEmpty) {
                      refresh(() => error = '項目名を入力してください。');
                      return;
                    }
                    _changeData(() {
                      selectedAccount.fields.add(InformationField(
                        id: createId(), name: name,
                        value: preview!, type: InformationType.generated,
                        sensitive: previewSensitive || isPasswordName(name),
                        createdAt: DateTime.now(),
                        history: [FieldHistoryEntry(action: '候補を生成',
                            at: DateTime.now(), detail: '生成候補を保存。',
                             retainedValue: retainHistoryValues ? preview : null)],
                      ));
                    });
                    Navigator.pop(dialogContext);
                  },
                  child: const Text('候補として保存'),
                ),
              ],
            );
          },
        ),
      );
    } finally {
      prefixController.dispose();
      nameController.dispose();
      templateController.dispose();
      extractStartController.dispose();
      extractCountController.dispose();
    }
  }

  void _appendHistory(InformationField field, String action, String detail, {String? value}) {
     field.history.add(FieldHistoryEntry.withValue(action: action, at: DateTime.now(), detail: detail,
         retainedValue: retainHistoryValues ? value : null));
  }

  Future<void> _showFieldHistory(InformationField field) async {
    await showDialog<void>(context: context, builder: (dialogContext) => AlertDialog(
      title: Text('操作履歴：${field.name}'),
      content: SizedBox(width: 460, height: 320, child: field.history.isEmpty
          ? const Center(child: Text('この版より前の操作履歴はありません。'))
          : ListView(children: [for (final event in field.history.reversed)
              ListTile(
                title: Text(event.action),
                subtitle: Text('${event.at.toLocal()}\n${event.detail}'
                     '${event.retainedValue == null ? '' : '\n保持値：${field.sensitive ? '••••••••' : event.retainedValue}'}'),
              )])),
      actions: [TextButton(onPressed: () => Navigator.pop(dialogContext),
          child: const Text('閉じる'))],
    ));
  }

  Future<void> editPersonaName() async {
    final result = await editTextDialog('デジタル人格の表示名', ['表示名'],
        initialValues: [personaName]);
    if (result == null || !mounted) return;
    _changeData(() => personaName = result.first);
  }

  Future<void> editField(InformationField field) async {
    final values = await editTextDialog(
      '情報を編集',
      ['項目名', '値'],
      initialValues: [field.name, field.value],
      protectedIndexes: field.sensitive ? const {1} : const {},
    );

    if (values == null || !mounted) return;

    _changeData(() {
      final changedName = field.name != values[0];
      final changedValue = field.value != values[1];
      field.name = values[0];
      field.value = values[1];
      if (changedName || changedValue) {
        _appendHistory(field, '手動編集',
            '${changedName ? '項目名を変更。' : ''}${changedValue ? '値を変更（値は履歴に保存しません）。' : ''}');
      }
    });
  }

  // 生成候補の確定は常に明示操作とする。候補は履歴として残す。
  Future<void> confirmGeneratedField(Account account, InformationField candidate) async {
    if (candidate.type != InformationType.generated) return;
    final matches = account.fields.where((field) =>
        field.type == InformationType.registered && field.name == candidate.name).toList();
    final existing = matches.isEmpty ? null : matches.first;
    final choice = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('生成候補を登録情報として確定'),
        content: Text(existing == null
            ? '「${candidate.name}」を登録済み情報へコピーします。生成候補は履歴として残ります。実際のサービスへの登録は行いません。'
            : '同名の登録済み項目があります。追加するか、既存項目を更新するか選択してください。生成候補は残ります。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('キャンセル')),
          if (existing != null)
            OutlinedButton(onPressed: () => Navigator.pop(dialogContext, 'replace'),
                child: const Text('既存項目を更新')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, 'add'),
              child: Text(existing == null ? '確定して追加' : '別項目として追加')),
        ],
      ),
    );
    if (choice == null || !mounted) return;
    _changeData(() {
      if (choice == 'replace' && existing != null) {
        existing.value = candidate.value;
        existing.sensitive = candidate.sensitive;
        _appendHistory(existing, '生成候補から更新', '候補ID：${candidate.id}。', value: candidate.value);
      } else {
        account.fields.add(InformationField(
          id: createId(),
          name: candidate.name,
          value: candidate.value,
          type: InformationType.registered,
          sensitive: candidate.sensitive,
          history: [FieldHistoryEntry(action: '候補から登録済み情報へ追加',
              at: DateTime.now(), detail: '候補ID：${candidate.id}。外部サイトには送信していません。',
               retainedValue: retainHistoryValues ? candidate.value : null)],
        ));
      }
      candidate.confirmedAt = DateTime.now();
      _appendHistory(candidate, '登録情報への確定',
          choice == 'replace' ? '既存項目ID：${existing?.id}を更新。' : '登録済み項目として追加。',
           value: candidate.value);
    });
  }

  Future<void> _copyField(InformationField field) async {
    await _copyProtected(field.value, sensitive: field.sensitive);
    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('値をクリップボードにコピーしました。共有PCでは貼り付け先に注意してください。')),
    );
  }

  Widget _fieldValue(InformationField field) {
    final visible = !field.sensitive || _revealedFields.contains(field.id);
    final value = visible ? field.value : '••••••••••••';
    if (field.type != InformationType.generated) return Text(value);
    final created = field.createdAt?.toLocal();
    final confirmed = field.confirmedAt?.toLocal();
    String format(DateTime date) =>
        '${date.year}/${date.month.toString().padLeft(2, '0')}/${date.day.toString().padLeft(2, '0')} '
        '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(value),
        Text('生成：${created == null ? '旧版データ（日時なし）' : format(created)}'
            '${confirmed == null ? '' : '  /  確定：${format(confirmed)}'}',
            style: const TextStyle(fontSize: 11)),
      ],
    );
  }

  Widget _fieldActions(InformationField field, Account account) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: field.sensitive
              ? (_revealedFields.contains(field.id) ? '値を隠す' : '値を表示')
              : '機密項目として隠す',
          icon: Icon(field.sensitive
              ? (_revealedFields.contains(field.id)
                  ? Icons.visibility_off_outlined : Icons.visibility_outlined)
              : Icons.lock_outline),
          onPressed: () {
            if (!field.sensitive) {
              _changeData(() => field.sensitive = true);
            } else {
              setState(() {
                if (!_revealedFields.remove(field.id)) {
                  _revealedFields.add(field.id);
                }
              });
            }
          },
        ),
        if (field.sensitive)
          IconButton(
            tooltip: '機密指定を解除',
            icon: const Icon(Icons.lock_open_outlined),
            onPressed: () => _unprotectField(field),
          ),
        IconButton(
          tooltip: '操作履歴',
          icon: const Icon(Icons.history_outlined),
          onPressed: () => _showFieldHistory(field),
        ),
        if (field.type == InformationType.registered)
          IconButton(
            tooltip: field.disclosureSelected ? '提供候補から除外' : '提供候補として選択',
            icon: Icon(field.disclosureSelected
                ? Icons.check_box_outlined : Icons.check_box_outline_blank),
            onPressed: () => _changeData(() {
              field.disclosureSelected = !field.disclosureSelected;
              _appendHistory(field, '提供候補の選択変更',
                  field.disclosureSelected ? '提供候補として選択。' : '提供候補から除外。');
            }),
          ),
        if (field.type == InformationType.generated)
          IconButton(
            tooltip: '登録済み情報へ確定',
            icon: const Icon(Icons.check_circle_outline),
            onPressed: () => confirmGeneratedField(account, field),
          ),
        IconButton(
          tooltip: '値をコピー',
          icon: const Icon(Icons.copy_outlined),
          onPressed: () => _copyField(field),
        ),
        IconButton(
          tooltip: '編集',
          onPressed: () => editField(field),
          icon: const Icon(Icons.edit_outlined),
        ),
        IconButton(
          tooltip: '削除',
          onPressed: () async {
            if (await confirmDelete(field.name) && mounted) {
              _changeData(() {
                account.fields.remove(field);
                _revealedFields.remove(field.id);
              });
            }
          },
          icon: const Icon(Icons.delete_outline),
        ),
      ],
    );
  }

    Future<bool> _confirmUnprotect(String name) async {
    if (!warnOnUnprotect) return true;
    return await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('機密指定を解除しますか？'),
      content: Text('「$name」の値が画面に表示されやすくなります。保存データの暗号化は継続します。'),
      actions: [TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('キャンセル')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('解除する'))],
    )) ?? false;
  }

  Future<void> _unprotectField(InformationField field) async {
    if (!await _confirmUnprotect(field.name) || !mounted) return;
    _changeData(() { field.sensitive = false; _revealedFields.remove(field.id);
      _appendHistory(field, '機密指定解除', '利用者が機密指定を解除。'); });
  }

  Future<void> _unprotectMaster(MasterField field) async {
    if (!await _confirmUnprotect(field.name) || !mounted) return;
    _changeData(() { field.sensitive = false; _revealedFields.remove('master_${field.id}'); });
  }

  Future<void> _changeRetainHistoryValues(bool enabled) async {
    if (enabled) { _changeData(() => retainHistoryValues = true); return; }
    final erase = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('履歴の実データ保持を停止'),
      content: const Text('既存の履歴に保存済みの実データも削除しますか？「既存値を保持」は今後の履歴にのみ適用されます。'),
      actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('キャンセル')),
        OutlinedButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('既存値を保持')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('既存値も削除'))],
    ));
    if (erase == null || !mounted) return;
    _changeData(() { retainHistoryValues = false;
      if (erase) { for (final service in services) { for (final account in service.accounts) {
        for (final field in account.fields) { for (final event in field.history) { event.retainedValue = null; } }
      } } }
    });
  }

  Future<void> _addMasterTemplates() async {
    final existing = masterFields.map((f) => f.name).toSet();
    final available = masterTemplates.where((name) => !existing.contains(name)).toList();
    if (available.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('追加できるテンプレート項目はありません。')));
      return;
    }
    final selected = available.toSet();
    final controllers = {for (final name in available) name: TextEditingController()};
    try {
      final accepted = await showDialog<bool>(context: context,
        builder: (ctx) => StatefulBuilder(builder: (ctx, refresh) => AlertDialog(
          title: const Text('マスター情報のテンプレート'),
          content: SizedBox(width: 520, height: 460, child: Column(children: [
            const Text('項目を選び、必要なら値も入力してください。既存項目は変更しません。'),
            Expanded(child: ListView(children: [for (final name in available)
              Row(children: [
                Checkbox(value: selected.contains(name), onChanged: (v) => refresh(() {
                  if (v == true) { selected.add(name); } else { selected.remove(name); }
                })),
                SizedBox(width: 140, child: Text(name)),
                Expanded(child: TextField(controller: controllers[name],
                  enabled: selected.contains(name),
                  obscureText: isPasswordName(name),
                  decoration: const InputDecoration(labelText: '値（任意）'))),
              ])])),
          ])),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('キャンセル')),
            FilledButton(onPressed: selected.isEmpty ? null : () => Navigator.pop(ctx, true),
              child: Text('${selected.length}項目を作成'))],
        )),
      ) ?? false;
      if (!accepted || !mounted) return;
      _changeData(() { masterCreated = true;
        for (final name in available.where(selected.contains)) {
          masterFields.add(MasterField(id: createId(), name: name, value: controllers[name]!.text));
        }
      });
    } finally {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        for (final controller in controllers.values) { controller.dispose(); }
      });
    }
  }

  Future<void> addMasterField() async {
    final values = await editTextDialog('マスター情報を追加', ['項目名', '値'], protectedIndexes: const {1});
    if (values == null || !mounted) return;
    _changeData(() {
      masterFields.add(MasterField(
        id: createId(), name: values[0], value: values[1],
      ));
    });
  }

  Future<void> editMasterField(MasterField field) async {
    final values = await editTextDialog(
      'マスター情報を編集', ['項目名', '値'],
      initialValues: [field.name, field.value],
      protectedIndexes: field.sensitive ? const {1} : const {},
    );
    if (values == null || !mounted) return;
    _changeData(() {
      field.name = values[0];
      field.value = values[1];
    });
  }

  Future<void> copyMasterField(MasterField field) async {
    await _copyProtected(field.value, sensitive: field.sensitive);
    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('マスター情報をコピーしました。クリップボードの扱いに注意してください。')),
    );
  }

  Widget buildMaster() {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const Text('マスター情報は任意です。アカウント追加時に選択した項目だけをコピーできます。'),
        const SizedBox(height: 16),
        if (!masterCreated) ...[
          const Text('マスター情報はまだ作成されていません。作成せずにサービスを管理できます。'),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.icon(
              onPressed: _addMasterTemplates,
              icon: const Icon(Icons.add),
              label: const Text('テンプレートから作成'),
            ),
          ),
        ] else ...[
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: _addMasterTemplates,
                icon: const Icon(Icons.playlist_add),
                label: const Text('テンプレート項目を追加'),
              ),
              FilledButton.icon(
                onPressed: addMasterField,
                icon: const Icon(Icons.add),
                label: const Text('項目を追加'),
              ),
              OutlinedButton.icon(
                onPressed: () async {
                  if (!await confirmDelete('マスター情報の全項目') || !mounted) return;
                  _changeData(() {
                    for (final field in masterFields) {
                      _revealedFields.remove('master_${field.id}');
                    }
                    masterFields.clear();
                    masterCreated = false;
                  });
                },
                icon: const Icon(Icons.delete_outline),
                label: const Text('マスター情報を削除'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (masterFields.isEmpty)
            const Text('項目はまだありません。必要な情報だけ追加してください。'),
          for (final field in masterFields)
            Card(
              child: ListTile(
                title: Text(field.name),
                subtitle: Text(
                  !field.sensitive || _revealedFields.contains('master_${field.id}')
                      ? field.value : '••••••••••••',
                ),
                trailing: Wrap(
                  spacing: 0,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    IconButton(
                      tooltip: field.sensitive
                          ? (_revealedFields.contains('master_${field.id}') ? '隠す' : '表示')
                          : '機密指定',
                      icon: Icon(field.sensitive
                          ? (_revealedFields.contains('master_${field.id}')
                              ? Icons.visibility_off_outlined : Icons.visibility_outlined)
                          : Icons.lock_outline),
                      onPressed: () {
                        if (!field.sensitive) {
                          _changeData(() => field.sensitive = true);
                        } else {
                          setState(() {
                            final key = 'master_${field.id}';
                            if (!_revealedFields.remove(key)) _revealedFields.add(key);
                          });
                        }
                      },
                    ),
                    if (field.sensitive)
                      IconButton(
                        tooltip: '機密指定を解除',
                        icon: const Icon(Icons.lock_open_outlined),
                        onPressed: () => _unprotectMaster(field),
                      ),
                    IconButton(
                      tooltip: 'コピー',
                      icon: const Icon(Icons.copy_outlined),
                      onPressed: () => copyMasterField(field),
                    ),
                    IconButton(
                      tooltip: '編集',
                      icon: const Icon(Icons.edit_outlined),
                      onPressed: () => editMasterField(field),
                    ),
                    IconButton(
                      tooltip: '削除',
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () async {
                        if (!await confirmDelete(field.name) || !mounted) return;
                        _changeData(() {
                          masterFields.remove(field);
                          _revealedFields.remove('master_${field.id}');
                        });
                      },
                    ),
                  ],
                ),
              ),
            ),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (_storageFailed) {
      return Scaffold(body: Center(child: Padding(
        padding: const EdgeInsets.all(32),
        child: SelectableText(_storageMessage ?? '保存領域のエラーが発生しました。'),
      )));
    }
    if (_locked) {
      return Scaffold(body: Center(child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.lock_outline, size: 56),
          const SizedBox(height: 16),
          const Text('MyCATTLES はロックされています'),
          const SizedBox(height: 12),
          FilledButton(onPressed: _securityBusy ? null : _unlock,
              child: const Text('PINで解除')),
          if (_securityError != null) Text(_securityError!,
              style: TextStyle(color: Theme.of(context).colorScheme.error)),
        ]),
      )));
    }
    if (_showFirstWarning) {
      return Scaffold(body: Center(child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 600),
        child: Card(child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('ご利用前の重要事項', style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 16),
            const Text('Phase 1では別端末へ復元できる暗号化バックアップを提供しません。'
                '端末の故障・紛失、OS再インストール、復号鍵の消失などにより、'
                '登録情報・パスワードを復元できなくなる可能性があります。'),
            const SizedBox(height: 12),
            const Text('保存データは暗号化されていますが、アプリロックを無効にした場合、'
                '画面の保護は主にOSのログイン管理に依存します。'
                '秘密情報のコピー先や共有PCでの操作にも注意してください。'),
            const SizedBox(height: 20),
            FilledButton(onPressed: _securityBusy ? null : _acknowledgeFirstWarning,
                child: const Text('内容を確認して続行')),
            if (_securityError != null) Text(_securityError!),
          ]),
        )),
      )));
    }
    return Scaffold(
      body: AbsorbPointer(absorbing: _securityBusy, child: Row(
        children: [
          NavigationRail(
            extended: true,
            minExtendedWidth: 200,
            selectedIndex: selectedIndex,
            onDestinationSelected: (index) {
               setState(() {
                 if (index == 1) { _jumpServiceId = null; _jumpAccountId = null;
                   _expandedCandidates.clear(); _serviceExpansionEpoch++; }
                 selectedIndex = index;
               });
            },
            leading: const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Text(
                'MyCATTLES',
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            destinations: List.generate(
              titles.length,
              (i) => NavigationRailDestination(
                icon: Icon(icons[i]),
                label: Text(titles[i]),
              ),
            ),
          ),
          const VerticalDivider(width: 1),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    titles[selectedIndex],
                    style: Theme.of(context).textTheme.headlineMedium,
                  ),
                ),
                const Divider(height: 1),
                Expanded(child: buildPage()),
              ],
            ),
          ),
        ],
      )),
    );
  }

  Widget buildPage() {
    switch (selectedIndex) {
      case 0:
        return buildHome();
      case 1:
        return buildServices();
      case 2:
        return buildGenerated();
      case 3:
        return buildMaster();
      case 4:
        return buildSettings();
      case 5:
        return buildDisclosure();
      default:
        return const SizedBox.shrink();
    }
  }

  Widget buildDisclosure() {
    final selected = <({Service service, Account account, InformationField field})>[];
    for (final service in services) {
      for (final account in service.accounts) {
        for (final field in account.fields) {
          if (field.type == InformationType.registered && field.disclosureSelected) {
            selected.add((service: service, account: account, field: field));
          }
        }
      }
    }
    return ListView(padding: const EdgeInsets.all(24), children: [
      const Text('外部サイトへ提供する可能性がある項目を、登録済み情報から明示的に選択します。'),
      const Text('ここでの選択は端末内の管理用です。情報の送信・フォーム入力・サイト登録は行いません。'),
      const SizedBox(height: 16),
      Text('選択済み：${selected.length}項目',
          style: Theme.of(context).textTheme.titleMedium),
      if (selected.isEmpty) const Padding(
          padding: EdgeInsets.all(16), child: Text('まだ選択されていません。登録サービス画面のチェックボックスから選択してください。')),
      for (final item in selected)
        Card(child: ListTile(
          title: Text('${item.service.name} / ${item.account.name} / ${item.field.name}'),
          subtitle: Text(item.field.sensitive ? '値：非表示（機密情報）' : '値：${item.field.value}'),
          trailing: IconButton(
            tooltip: '提供候補から除外', icon: const Icon(Icons.remove_circle_outline),
            onPressed: () => _changeData(() {
              item.field.disclosureSelected = false;
              _appendHistory(item.field, '提供候補の選択変更', '提供候補から除外。');
            }),
          ),
        )),
    ]);
  }

  Future<void> _editClipboardSeconds() async {
    final controller = TextEditingController(text: '$clipboardSeconds');
    String? error;
    try {
      final value = await showDialog<int>(context: context,
        builder: (dialogContext) => StatefulBuilder(builder: (dialogContext, refresh) => AlertDialog(
          title: const Text('クリップボード保持時間'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: controller, autofocus: true,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: '秒数（1～3600）')),
            if (error != null) Text(error!, style: TextStyle(
                color: Theme.of(dialogContext).colorScheme.error)),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('キャンセル')),
            FilledButton(onPressed: () {
              final parsed = int.tryParse(controller.text.trim());
              if (parsed == null || parsed < 1 || parsed > 3600) {
                refresh(() => error = '1～3600の整数を入力してください。');
                return;
              }
              Navigator.pop(dialogContext, parsed);
            }, child: const Text('保存')),
          ],
        )),
      );
      if (value != null && mounted) _changeData(() => clipboardSeconds = value);
    } finally {
      WidgetsBinding.instance.addPostFrameCallback((_) => controller.dispose());
    }
  }

  // F-043: 平文JSONによる緊急退避。既存保管庫の暗号化形式は変更しない。
  Future<String?> _askJsonPath({required bool export}) async {
    final controller = TextEditingController();
    try {
      return await showDialog<String>(context: context, builder: (ctx) => AlertDialog(
        title: Text(export ? '緊急エクスポートの保存先' : '緊急復元ファイル'),
        content: SizedBox(width: 540, child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(export ? '保存するJSONファイルの絶対パスを入力してください。既存ファイルは上書きしません。'
              : '読み込むJSONファイルの絶対パスを入力してください。'),
          TextField(controller: controller, autofocus: true,
            decoration: const InputDecoration(hintText: r'C:\Users\...\mycattles_emergency.json')),
        ])),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('キャンセル')),
          FilledButton(onPressed: () => Navigator.pop(ctx, controller.text.trim()), child: const Text('次へ'))],
      ));
    } finally {
      WidgetsBinding.instance.addPostFrameCallback((_) => controller.dispose());
    }
  }

  Future<bool> _authorizeEmergency() async {
    if (_lockPin == null) return true;
    final pin = await _askPin(title: '緊急データ操作：PIN再認証');
    if (pin == null) return false;
    if (!_verifyPin(pin)) throw const FormatException('PINの認証に失敗しました。');
    return true;
  }

  Future<void> _exportEmergency() async {
    if (_loading || _storageFailed || _securityBusy || _locked) return;
    final accepted = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('平文JSONの危険性を確認'),
      content: const SizedBox(width: 500, child: Text(
        '出力ファイルは暗号化されません。氏名、連絡先、登録情報、生成候補などが第三者に読まれる可能性があります。'
        'クラウド同期フォルダや共有フォルダへの保存は避け、復元後は安全に保管または削除してください。'
        '\n\nパスワード・機密指定項目は初期状態では出力しません。含める場合は次の画面で明示的に選択してください。')),
      actions: [TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('中止')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('リスクを理解して続行'))],
    )) ?? false;
    if (!accepted || !mounted) return;
    bool passwords = false;
    bool histories = false;
    final options = await showDialog<bool>(context: context, builder: (ctx) => StatefulBuilder(
      builder: (ctx, refresh) => AlertDialog(title: const Text('出力内容を選択'), content: Column(
        mainAxisSize: MainAxisSize.min, children: [
          CheckboxListTile(value: passwords, title: const Text('パスワード・機密指定項目を含める（危険）'),
            onChanged: (v) => refresh(() => passwords = v ?? false)),
          CheckboxListTile(value: histories, title: const Text('操作履歴を含める'),
            onChanged: (v) => refresh(() => histories = v ?? false)),
          const Text('除外された項目は復元できません。完全バックアップではありません。'),
        ]), actions: [TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('中止')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('確定'))],
      ),
    )) ?? false;
    if (!options || !mounted) return;
    try {
      if (!await _authorizeEmergency() || !mounted) return;
      final path = await _askJsonPath(export: true);
      if (path == null || path.isEmpty || !mounted) return;
      setState(() => _securityBusy = true);
      await _saveChain; // 未完了の保存を待つ。
      if (_storageFailed) throw StateError('保存エラーがあるため出力できません。');
      final data = jsonDecode(jsonEncode(_snapshot())) as Map<String, dynamic>;
      for (final service in data['services'] as List<dynamic>) {
        for (final account in (service as Map<String, dynamic>)['accounts'] as List<dynamic>) {
          final fields = (account as Map<String, dynamic>)['fields'] as List<dynamic>;
          for (final field in fields) {
            final item = field as Map<String, dynamic>;
            if (!passwords && (item['sensitive'] == true || isPasswordName(item['name'] as String))) {
              // 秘密項目はフィールド自体を除外し、空文字を登録値として誤認させない。
              item['_omitEmergency'] = true;
            }
            if (!histories) {
              item['history'] = <dynamic>[];
            } else if (!passwords) {
              for (final event in item['history'] as List<dynamic>) {
                (event as Map<String, dynamic>).remove('retainedValue');
              }
            }
          }
          fields.removeWhere((f) => (f as Map<String, dynamic>).remove('_omitEmergency') == true);
        }
      }
      if (!passwords && data['master'] is Map) {
        final fields = (data['master'] as Map<String, dynamic>)['fields'] as List<dynamic>;
        fields.removeWhere((f) => (f as Map<String, dynamic>)['sensitive'] == true ||
            isPasswordName(f['name'] as String));
      }
      final payload = <String, dynamic>{
        'exportFormat': 'mycattles-emergency-json', 'exportVersion': 1,
        'exportedAt': DateTime.now().toUtc().toIso8601String(),
        'includesSensitiveFields': passwords, 'includesHistory': histories,
        'data': data,
      };
      final file = File(path);
      if (!file.isAbsolute || !path.toLowerCase().endsWith('.json')) {
        throw const FormatException('絶対パスで拡張子 .json を指定してください。');
      }
      // exclusive creation: 既存ファイルを絶対に上書きしない。
      await file.create(exclusive: true);
      try {
        final handle = await file.open(mode: FileMode.writeOnlyAppend);
        try {
          await handle.writeString(const JsonEncoder.withIndent('  ').convert(payload));
          await handle.flush();
        } finally {
          await handle.close();
        }
      } catch (_) {
        try { if (await file.exists()) await file.delete(); } catch (_) {}
        rethrow;
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('緊急JSONを出力しました。平文ファイルの保管に注意してください。')),
        );
      }
    } catch (error) {
      if (mounted) setState(() => _securityError = '緊急エクスポートに失敗しました：$error');
    } finally {
      if (mounted) setState(() => _securityBusy = false);
    }
  }

  // 復元前に全階層の形式を検証する。既存データには触れない。
  void _validateEmergency(Map<String, dynamic> data) {
    if (data['schemaVersion'] != 1 || data['nextId'] is! int ||
        data['services'] is! List || (data['nextId'] as int) < 0) {
      throw const FormatException('未対応のデータ形式です。');
    }
    final preferences = data['preferences'];
    if (preferences != null && preferences is! Map) {
      throw const FormatException('設定情報が不正です。');
    }
    if (preferences is Map) {
      for (final name in ['hideMasterPrompt', 'warnOnUnprotect', 'retainHistoryValues']) {
        if (preferences[name] != null && preferences[name] is! bool) {
          throw const FormatException('設定値が不正です。');
        }
      }
      if (preferences['clipboardSeconds'] != null &&
          (preferences['clipboardSeconds'] is! int ||
           (preferences['clipboardSeconds'] as int) < 1 ||
           (preferences['clipboardSeconds'] as int) > 3600)) {
        throw const FormatException('クリップボード設定が不正です。');
      }
    }
    final ids = <String>{};
    void checkId(dynamic id) {
      if (id is! String || id.isEmpty || !ids.add(id)) {
        throw const FormatException('IDが不正または重複しています。');
      }
    }
    final master = data['master'];
    if (master != null) {
      if (master is! Map || master['fields'] is! List) throw const FormatException('マスター情報が不正です。');
      for (final raw in master['fields'] as List) {
        if (raw is! Map || raw['name'] is! String || raw['value'] is! String) {
          throw const FormatException('マスター項目が不正です。');
        }
        checkId(raw['id']);
      }
    }
    for (final rawService in data['services'] as List) {
      if (rawService is! Map || rawService['name'] is! String ||
          rawService['url'] is! String || rawService['accounts'] is! List) {
        throw const FormatException('サービス情報が不正です。');
      }
      checkId(rawService['id']);
      for (final rawAccount in rawService['accounts'] as List) {
        if (rawAccount is! Map || rawAccount['name'] is! String || rawAccount['fields'] is! List ||
            rawAccount['registrationStatus'] is! String || rawAccount['usageStatus'] is! String) {
          throw const FormatException('アカウント情報が不正です。');
        }
        checkId(rawAccount['id']);
        for (final rawField in rawAccount['fields'] as List) {
          if (rawField is! Map || rawField['name'] is! String || rawField['value'] is! String ||
              rawField['type'] is! String) {
            throw const FormatException('登録項目が不正です。');
          }
          checkId(rawField['id']);
          if (rawField['history'] != null && rawField['history'] is! List) {
            throw const FormatException('履歴が不正です。');
          }
        }
      }
    }
    for (final service in data['services'] as List) {
      for (final account in (service as Map)['accounts'] as List) {
        final a = account as Map;
        final reg = a['registrationStatus'] as String;
        final usage = a['usageStatus'] as String;
        if (reg != 'unconfirmed' && reg != 'confirmed' &&
            !RegistrationStatus.values.any((e) => e.name == reg)) {
          throw const FormatException('登録確認状態が不正です。');
        }
        if (!['inactive', 'closed'].contains(usage) &&
            !UsageStatus.values.any((e) => e.name == usage)) {
          throw const FormatException('利用状況が不正です。');
        }
        for (final field in a['fields'] as List) {
          final f = field as Map;
          if (!InformationType.values.any((e) => e.name == f['type'])) {
            throw const FormatException('情報種別が不正です。');
          }
          for (final history in (f['history'] as List? ?? [])) {
            if (history is! Map || (history['action'] != null && history['action'] is! String) ||
                (history['detail'] != null && history['detail'] is! String) ||
                (history['at'] != null && (history['at'] is! String || DateTime.tryParse(history['at'] as String) == null)) ||
                (history['retainedValue'] != null && history['retainedValue'] is! String)) {
              throw const FormatException('履歴形式が不正です。');
            }
          }
        }
      }
    }
    // 保存前に全ての必須構造を検証する。
    final test = jsonDecode(jsonEncode(data)) as Map<String, dynamic>;
    // _restore はここでは呼ばない（既存状態の破壊を避ける）。
    if (test['services'] is! List) throw const FormatException('JSON構造が不正です。');
  }

  Future<void> _importEmergency() async {
    if (_loading || _storageFailed || _securityBusy || _locked) return;
    if (services.isNotEmpty || masterCreated || personaName != '自分' || nextId != 0) {
      setState(() => _securityError = '復元は空の保管庫でのみ実行できます。既存データは変更していません。');
      return;
    }
    try {
      if (!await _authorizeEmergency() || !mounted) return;
      final path = await _askJsonPath(export: false);
      if (path == null || path.isEmpty || !mounted) return;
      final file = File(path);
      if (!file.isAbsolute || !path.toLowerCase().endsWith('.json')) {
        throw const FormatException('絶対パスのJSONファイルを指定してください。');
      }
      if (await file.length() > 20 * 1024 * 1024) throw const FormatException('20MBを超えるJSONは読み込めません。');
      final raw = jsonDecode(await file.readAsString());
      if (raw is! Map<String, dynamic> || raw['exportFormat'] != 'mycattles-emergency-json' ||
          raw['exportVersion'] != 1 || raw['data'] is! Map<String, dynamic>) {
        throw const FormatException('MyCATTLES緊急JSON形式ではありません。');
      }
      final data = raw['data'] as Map<String, dynamic>;
      _validateEmergency(data);
      if (!mounted) return;
      final accepted = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
        title: const Text('緊急JSONを復元'),
        content: Text('サービス${(data['services'] as List).length}件を空の保管庫へ復元します。'
          '\n機密項目・履歴がエクスポート時に除外されていた場合は復元できません。'
          '\nJSONファイルは復元後も平文のまま残ります。'),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('中止')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('復元する'))],
      )) ?? false;
      if (!accepted || !mounted) return;
      setState(() => _securityBusy = true);
      await _saveChain;
      if (_storageFailed) throw StateError('保存エラーがあるため復元できません。');
      // 暗号化保存に成功してからUIを復元する。
      await _vault.save(data);
      if (!mounted) return;
      setState(() { _restore(data); _revealedFields.clear(); _securityError = null; });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('復元しました。元の平文JSONの取り扱いに注意してください。')));
    } catch (error) {
      if (mounted) setState(() => _securityError = '緊急復元に失敗しました：$error');
    } finally {
      if (mounted) setState(() => _securityBusy = false);
    }
  }

  Widget buildSettings() => ListView(
    padding: const EdgeInsets.all(24),
    children: [
      ListTile(
        leading: const Icon(Icons.person_outline),
        title: const Text('デジタル人格（Phase 1：単一）'),
        subtitle: Text('表示名：$personaName。全サービス・アカウントはこの人格に属します。'),
        trailing: OutlinedButton(onPressed: editPersonaName, child: const Text('表示名を変更')),
      ),
      const Divider(),
      ListTile(
        leading: const Icon(Icons.brightness_6_outlined),
        title: const Text('表示テーマ'),
        trailing: DropdownButton<ThemeMode>(
          value: themeMode,
          items: const [
            DropdownMenuItem(value: ThemeMode.system, child: Text('システム設定')),
            DropdownMenuItem(value: ThemeMode.light, child: Text('ライト')),
            DropdownMenuItem(value: ThemeMode.dark, child: Text('ダーク')),
          ],
          onChanged: (value) {
            if (value == null) return;
            appTheme.value = value;
            _changeData(() => themeMode = value);
          },
        ),
      ),
      if (Platform.isWindows) const ListTile(
        leading: Icon(Icons.open_in_full_outlined),
        title: Text('ウィンドウサイズ・位置'),
        subtitle: Text('変更後に自動保存し、次回起動時に復元します。'),
      ),
      ListTile(
        leading: const Icon(Icons.lock_outline),
        title: const Text('アプリ起動時のPINロック'),
        subtitle: Text(_lockPin == null
            ? '無効：アプリの画面保護はOSのログイン認証に依存します。'
            : '有効：次回起動時にPIN入力が必要です。'),
        trailing: Switch(
          value: _lockPin != null,
          onChanged: _securityBusy ? null : (value) {
            if (value) { _enableLock(); } else { _disableLock(); }
          },
        ),
      ),
      if (_lockPin != null) SwitchListTile(
        secondary: const Icon(Icons.lock_clock_outlined),
        title: const Text('無操作時に自動ロック'),
        subtitle: const Text('アプリ内のマウス・キーボード操作を基準にします。'),
        value: autoLockEnabled,
        onChanged: (value) {
          _changeData(() => autoLockEnabled = value);
          _resetIdleTimer();
        },
      ),
      if (_lockPin != null && autoLockEnabled) ListTile(
        leading: const Icon(Icons.timer_outlined),
        title: const Text('自動ロックまでの時間'),
        trailing: DropdownButton<int>(
          value: autoLockMinutes,
          items: const [1, 5, 10, 15, 30].map((m) =>
            DropdownMenuItem(value: m, child: Text('$m 分'))).toList(),
          onChanged: (value) {
            if (value == null) return;
            _changeData(() => autoLockMinutes = value);
            _resetIdleTimer();
          },
        ),
      ),
      if (_lockPin != null) ListTile(
        leading: const Icon(Icons.screen_lock_portrait_outlined),
        title: const Text('今すぐロック'),
        trailing: OutlinedButton(
          onPressed: _securityBusy ? null : () => setState(() {
            _revealedFields.clear();
            _locked = true;
            _idleTimer?.cancel();
          }),
          child: const Text('ロックする'),
        ),
      ),
      ListTile(
        leading: const Icon(Icons.content_paste_off_outlined),
        title: const Text('クリップボード保護の対象'),
        subtitle: const Text('消去対象を選択します。OSのクリップボード履歴は消去できません。'),
        trailing: DropdownButton<ClipboardProtection>(
          value: clipboardProtection,
          items: const [
            DropdownMenuItem(value: ClipboardProtection.all, child: Text('すべての情報')),
            DropdownMenuItem(value: ClipboardProtection.sensitive, child: Text('機密情報のみ')),
            DropdownMenuItem(value: ClipboardProtection.off, child: Text('自動消去しない')),
          ],
          onChanged: (value) {
            if (value != null) _changeData(() => clipboardProtection = value);
          },
        ),
      ),
      ListTile(
        leading: const Icon(Icons.timer_outlined),
        title: const Text('クリップボード保持時間'),
        subtitle: Text('$clipboardSeconds 秒後に消去を試みます（1～3600秒）。'),
        trailing: OutlinedButton(onPressed: _editClipboardSeconds,
            child: const Text('秒数を変更')),
      ),
      const ListTile(
        leading: Icon(Icons.shield_outlined),
        title: Text('ローカル暗号化保存とデータ消失リスク'),
        subtitle: Text('保存データはアプリロックとは独立して暗号化されます。'
            'Phase 1では別端末復元用の暗号化バックアップは提供しません。'
            '故障・紛失・OS再インストール・鍵消失時に復元できない場合があります。'),
      ),
             const Divider(),
       SwitchListTile(
         secondary: const Icon(Icons.warning_amber_outlined),
         title: const Text('機密指定解除時の警告'),
         subtitle: const Text('オフにすると機密指定を確認なしで解除できます。'),
         value: warnOnUnprotect,
         onChanged: (value) => _changeData(() => warnOnUnprotect = value),
       ),
       SwitchListTile(
         secondary: const Icon(Icons.history_outlined),
         title: const Text('履歴に実データを保持'),
         subtitle: const Text('初期値はオフ。生成候補本体の値は保持されます。'),
         value: retainHistoryValues,
         onChanged: _changeRetainHistoryValues,
       ),
       const Divider(),
       ExpansionTile(
         key: const PageStorageKey('advanced_data_management'),
         initiallyExpanded: _advancedDataOpen,
         onExpansionChanged: (value) => _advancedDataOpen = value,
         leading: const Icon(Icons.admin_panel_settings_outlined),
         title: const Text('データ管理（詳細）'),
         subtitle: const Text('緊急JSON出力・復元と全データ初期化'),
         children: [
       const ListTile(leading: Icon(Icons.warning_amber_outlined),
         title: Text('緊急データ退避・復元（平文JSON）'),
         subtitle: Text('出力ファイルは暗号化されません。復元は空の保管庫に限ります。')),
       Wrap(spacing: 12, children: [
         OutlinedButton.icon(onPressed: _securityBusy ? null : _exportEmergency,
           icon: const Icon(Icons.file_upload_outlined), label: const Text('緊急JSONを出力')),
         OutlinedButton.icon(onPressed: _securityBusy ? null : _importEmergency,
           icon: const Icon(Icons.file_download_outlined), label: const Text('緊急JSONから復元')),
       ]),
       const Divider(),
       ListTile(
         leading: const Icon(Icons.delete_forever_outlined),
        title: const Text('全データ初期化'),
        subtitle: const Text('全サービス・アカウント・生成情報・マスター情報・認証情報を削除し、'
            'アプリ管理の暗号化ファイルと復号鍵を消去します。PIN設定は維持します。'),
        trailing: OutlinedButton(
          onPressed: _securityBusy ? null : _resetAllData,
          child: const Text('初期化'),
        ),
      ),
       ],
       ),
      if (_securityBusy) const LinearProgressIndicator(),
      if (_securityError != null) Text(_securityError!,
          style: TextStyle(color: Theme.of(context).colorScheme.error)),
    ],
  );

  Widget buildHome() {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const Text(
          'MyCATTLESへようこそ',
          style: TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 8),
        const Text('私の、私による、私のためのプライバシー管理システム。'),
        const SizedBox(height: 24),
        if (!masterCreated && !hideMasterPrompt) ...[
          Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('マスター情報を登録しませんか？',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              const Text('任意の機能です。テンプレートから項目を作成できます。登録しなくても利用できます。'),
              const SizedBox(height: 8),
              Wrap(spacing: 12, children: [
                FilledButton(onPressed: () => setState(() => selectedIndex = 3),
                    child: const Text('マスター情報へ')),
                TextButton(onPressed: () => _changeData(() => hideMasterPrompt = true),
                    child: const Text('二度と表示しない')),
              ]),
            ],
          ))),
          const SizedBox(height: 16),
        ],
        Wrap(
          spacing: 16,
          runSpacing: 16,
          children: [
            summaryCard('登録サービス', services.length),
            summaryCard('アカウント', accountCount),
            summaryCard('生成候補情報', generatedCount),
            summaryCard('未確定候補', services.fold<int>(0, (sum, service) =>
                sum + service.accounts.fold<int>(0, (total, account) =>
                    total + account.fields.where((field) =>
                        field.type == InformationType.generated && field.confirmedAt == null).length))),
            summaryCard('利用中アカウント', services.fold<int>(0, (sum, service) =>
                sum + service.accounts.where((account) => account.usageStatus == UsageStatus.active).length)),
          ],
        ),
        const SizedBox(height: 24),
        FilledButton.icon(
          onPressed: () => setState(() => selectedIndex = 1),
          icon: const Icon(Icons.arrow_forward),
          label: const Text('登録サービスを管理'),
        ),
        const SizedBox(height: 16),
        const Text(
          '試作版：変更内容はこのWindowsユーザーのローカル領域に暗号化保存されます。' ,
        ),
      ],
    );
  }

  Widget summaryCard(String title, int count) {
    return SizedBox(
      width: 210,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title),
              const SizedBox(height: 12),
              Text(
                '$count',
                style: const TextStyle(
                  fontSize: 32,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  bool _serviceMatches(Service service) {
    final query = _serviceQuery;
    final textMatch = query.isEmpty ||
        service.name.toLowerCase().contains(query) ||
        service.url.toLowerCase().contains(query) ||
        service.accounts.any((account) =>
            account.name.toLowerCase().contains(query) ||
            account.fields.any((field) => field.name.toLowerCase().contains(query)));
    final statusMatch = _serviceUsageFilter == 'all' ||
        service.accounts.any((account) => account.usageStatus.name == _serviceUsageFilter);
    return textMatch && statusMatch;
  }

  List<Service> get _visibleServices {
    final result = services.where(_serviceMatches).toList();
    result.sort((a, b) {
      if (_serviceSort == 'accounts') {
        final compare = b.accounts.length.compareTo(a.accounts.length);
        if (compare != 0) return compare;
      }
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return result;
  }

  bool _generatedMatches(Service service, Account account, InformationField field) {
    if (field.type != InformationType.generated) return false;
    if (_generatedFilter == 'confirmed' && field.confirmedAt == null) return false;
    if (_generatedFilter == 'pending' && field.confirmedAt != null) return false;
    final query = _generatedQuery;
    return query.isEmpty || service.name.toLowerCase().contains(query) ||
        account.name.toLowerCase().contains(query) || field.name.toLowerCase().contains(query);
  }

  Widget buildServices() {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        TextField(
          controller: _serviceSearchController,
          decoration: InputDecoration(
            labelText: 'サービスを検索',
            hintText: 'サービス名・URL・アカウント名',
            prefixIcon: const Icon(Icons.search),
            suffixIcon: _serviceQuery.isEmpty ? null : IconButton(
              tooltip: '検索をクリア',
              icon: const Icon(Icons.clear),
              onPressed: () {
                _serviceSearchController.clear();
                setState(() => _serviceQuery = '');
              },
            ),
            border: const OutlineInputBorder(),
          ),
          onChanged: (value) => setState(() => _serviceQuery = value.trim().toLowerCase()),
        ),
        const SizedBox(height: 12),
        Wrap(spacing: 12, runSpacing: 8, children: [
          DropdownButton<String>(
            value: _serviceUsageFilter,
            items: const [
              DropdownMenuItem(value: 'all', child: Text('利用状況：すべて')),
              DropdownMenuItem(value: 'active', child: Text('利用中')),
              DropdownMenuItem(value: 'paused', child: Text('休止中')),
              DropdownMenuItem(value: 'ended', child: Text('利用終了')),
              DropdownMenuItem(value: 'unknown', child: Text('不明')),
            ],
            onChanged: (value) => setState(() => _serviceUsageFilter = value ?? 'all'),
          ),
          DropdownButton<String>(
            value: _serviceSort,
            items: const [
              DropdownMenuItem(value: 'name', child: Text('並び順：サービス名')),
              DropdownMenuItem(value: 'accounts', child: Text('アカウント数が多い順')),
            ],
            onChanged: (value) => setState(() => _serviceSort = value ?? 'name'),
          ),
          Text('表示 ${_visibleServices.length} / ${services.length} 件'),
        ]),
        const SizedBox(height: 16),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.icon(
            onPressed: addService,
             icon: const Icon(Icons.add),
             label: const Text('サービスを追加'),
          ),
        ),
                 const SizedBox(height: 8),
         Align(alignment: Alignment.centerLeft, child: OutlinedButton.icon(
           onPressed: () => generateCandidate(), icon: const Icon(Icons.auto_awesome),
           label: const Text('候補情報を自動生成'))),
         const SizedBox(height: 16),
         if (services.isEmpty)
          const Text('登録されたサービスはありません。'),
        if (services.isNotEmpty && _visibleServices.isEmpty)
          const Text('条件に一致するサービスはありません。'),
        for (final service in _visibleServices)
          Card(
            margin: const EdgeInsets.only(bottom: 12),
            child: ExpansionTile(
              key: ValueKey('service_${service.id}_${_jumpServiceId == service.id}_$_serviceExpansionEpoch'),
              initiallyExpanded: _jumpServiceId == service.id,
              title: Text(service.name),
              subtitle: Text(
                '${service.url.isEmpty ? "URL未設定" : service.url}'
                ' ・ ${service.accounts.length}アカウント',
              ),
              childrenPadding: const EdgeInsets.all(12),
              children: [
                Wrap(
                  spacing: 8,
                  children: [
                    OutlinedButton(
                      onPressed: () => editService(service),
                      child: const Text('サービス編集'),
                    ),
                    OutlinedButton(
                      onPressed: () => addAccount(service),
                      child: const Text('アカウント追加'),
                    ),
                    TextButton(
                      onPressed: () async {
                        if (await confirmDelete('${service.name}（${service.accounts.length}件のアカウント・認証情報・生成情報を含む全情報。バックアップからの物理的完全消去は保証されません）') &&
                            mounted) {
                          _changeData(() => services.remove(service));
                        }
                      },
                      child: const Text('サービス削除'),
                    ),
                  ],
                ),
                if (service.accounts.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(12),
                    child: Text('アカウントは未登録です。'),
                  ),
                for (final account in service.accounts)
                  buildAccount(service, account),
              ],
            ),
          ),
      ],
    );
  }

  Widget buildAccount(Service service, Account account) {
    return Card(
      child: ExpansionTile(
        key: ValueKey('account_${account.id}_${_jumpAccountId == account.id}_$_serviceExpansionEpoch'),
        initiallyExpanded: _jumpAccountId == account.id,
        title: Text(account.name),
        subtitle: Text(
          '${account.registrationStatus.label} / '
          '${account.usageStatus.label}',
        ),
        childrenPadding: const EdgeInsets.all(12),
        children: [
          Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              DropdownButton<RegistrationStatus>(
                value: account.registrationStatus,
                items: RegistrationStatus.values
                    .map(
                      (value) => DropdownMenuItem(
                        value: value,
                        child: Text('登録：${value.label}'),
                      ),
                    )
                    .toList(),
                onChanged: (value) {
                  if (value != null) {
                    _changeData(
                      () => account.registrationStatus = value,
                    );
                  }
                },
              ),
              DropdownButton<UsageStatus>(
                value: account.usageStatus,
                items: UsageStatus.values
                    .map(
                      (value) => DropdownMenuItem(
                        value: value,
                        child: Text('利用：${value.label}'),
                      ),
                    )
                    .toList(),
                onChanged: (value) {
                  if (value != null) {
                    _changeData(() => account.usageStatus = value);
                  }
                },
              ),
              TextButton(
                onPressed: () => editAccount(account),
                child: const Text('名前変更'),
              ),
              if (account.registrationStatus != RegistrationStatus.withdrawalConfirmed)
                TextButton.icon(
                  onPressed: () => _withdrawAccount(account),
                  icon: const Icon(Icons.archive_outlined),
                  label: const Text('退会済みとして保持'),
                ),
              TextButton(
                onPressed: () => _deleteAccountPermanently(service, account),
                child: const Text('アカウント情報を削除'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => generateCandidate(
                initialService: service, initialAccount: account,
              ),
              icon: const Icon(Icons.auto_awesome),
              label: const Text('候補情報を自動生成'),
            ),
          ),
          ExpansionTile(
            key: ValueKey('candidates_${account.id}_$_serviceExpansionEpoch'),
            initiallyExpanded: _expandedCandidates.contains(account.id) ||
                account.fields.any((f) => f.type == InformationType.generated && f.confirmedAt == null),
            onExpansionChanged: (expanded) => setState(() {
              if (expanded) { _expandedCandidates.add(account.id); }
              else { _expandedCandidates.remove(account.id); }
            }),
            title: Text('生成候補情報（${account.fields.where((f) => f.type == InformationType.generated).length}件）'),
            subtitle: const Text('折りたたんで表示できます'),
            children: [buildFieldSection(account, InformationType.generated, '候補一覧')],
          ),
          const Divider(),
          buildFieldSection(
            account,
            InformationType.registered,
            '登録済み情報',
          ),
        ],
      ),
    );
  }

  Widget buildFieldSection(
    Account account,
    InformationType type,
    String title,
  ) {
    final fields =
        account.fields.where((field) => field.type == type).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              title,
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(width: 12),
            TextButton.icon(
              onPressed: () => addField(account, type),
              icon: const Icon(Icons.add),
              label: const Text('追加'),
            ),
          ],
        ),
        if (fields.isEmpty)
          const Padding(
            padding: EdgeInsets.all(8),
            child: Text('情報はありません。'),
          ),
        for (final field in fields)
          ListTile(
            title: Text(field.name),
            subtitle: _fieldValue(field),
            trailing: _fieldActions(field, account),
          ),
      ],
    );
  }

  Widget buildGenerated() {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const Text(
          '生成情報の履歴',
          style: TextStyle(fontSize: 20),
        ),
        const SizedBox(height: 16),
        const Text('生成候補の記録を確認できます。新規生成や登録情報への確定は登録サービス画面で行います。'),
        const SizedBox(height: 12),
        const SizedBox(height: 16),
        TextField(
          controller: _generatedSearchController,
          decoration: InputDecoration(
            labelText: '生成候補を検索',
            hintText: 'サービス名・アカウント名・項目名',
            prefixIcon: const Icon(Icons.search),
            border: const OutlineInputBorder(),
            suffixIcon: _generatedQuery.isEmpty ? null : IconButton(
              tooltip: '検索をクリア',
              icon: const Icon(Icons.clear),
              onPressed: () {
                _generatedSearchController.clear();
                setState(() => _generatedQuery = '');
              },
            ),
          ),
          onChanged: (value) => setState(() => _generatedQuery = value.trim().toLowerCase()),
        ),
        const SizedBox(height: 8),
        Wrap(spacing: 12, children: [
          DropdownButton<String>(
            value: _generatedFilter,
            items: const [
              DropdownMenuItem(value: 'all', child: Text('確定状況：すべて')),
              DropdownMenuItem(value: 'pending', child: Text('未確定のみ')),
              DropdownMenuItem(value: 'confirmed', child: Text('確定済みのみ')),
            ],
            onChanged: (value) => setState(() => _generatedFilter = value ?? 'all'),
          ),
        ]),
        if (!services.any((service) => service.accounts.any((account) =>
            account.fields.any((field) => _generatedMatches(service, account, field)))))
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Text('条件に一致する生成候補はありません。'),
          ),
        for (final service in services)
          for (final account in service.accounts)
            for (final field in account.fields)
              if (_generatedMatches(service, account, field))
                Card(
                  child: ListTile(
                    title: Text('${service.name} / ${account.name}'),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [Text(field.name), _fieldValue(field)],
                    ),
                    trailing: IconButton(
                      tooltip: '登録サービスへ移動',
                      icon: const Icon(Icons.open_in_new),
                      onPressed: () => setState(() {
                        _serviceQuery = '';
                        _serviceSearchController.clear();
                        _serviceUsageFilter = 'all';
                        _jumpServiceId = service.id;
                        _jumpAccountId = account.id;
                        selectedIndex = 1;
                      }),
                    ),
                  ),
                ),
      ],
    );
  }
}
