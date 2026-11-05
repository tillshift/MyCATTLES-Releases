
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

import 'package:mycattles/main.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('iOS vault: save, restore and update', (tester) async {
    final vault = LocalVault();
    final directory = await getApplicationSupportDirectory();
    final file = File(
      '${directory.path}${Platform.pathSeparator}'
      'mycattles_vault_v1.enc',
    );

    // GitHub Actionsの専用シミュレーター上でのみ実行する。
    // 既存の保存データがあれば、誤消去を避けるため中止する。
    expect(await file.exists(), isFalse);

    final original = <String, dynamic>{
      'schemaVersion': 1,
      'testValue': 'iOS保存・復元テスト',
      'password': 'test-password-123',
    };

    await vault.save(original);

    expect(await file.exists(), isTrue);

    // 暗号化ファイルに平文が含まれないことを確認。
    final encrypted = await file.readAsString();
    expect(encrypted.contains('test-password-123'), isFalse);

    final restored = await LocalVault().load();
    expect(restored, equals(original));

    // 上書き保存と再読込。
    final updated = <String, dynamic>{
      ...original,
      'testValue': '更新後',
    };

    await vault.save(updated);

    final restoredAgain = await LocalVault().load();
    expect(restoredAgain, equals(updated));

    // バックアップファイルの生成を確認。
    expect(await File('${file.path}.bak').exists(), isTrue);

    // テスト終了後の削除。
    await vault.resetAll();

    expect(await file.exists(), isFalse);
  });
}
