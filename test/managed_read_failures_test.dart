import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 一个读取迁了平面，它的错误处理没跟着迁 —— 这条闸就是为它设的。
///
/// `HostDevicesRepository` 早就改走 `executeManagement`（管理面，拒绝以
/// `ManagementRequestException` 到达），而 `_loadDevices` 还点着
/// `LocalApiRequestException`。于是每一次主机给出的拒绝 —— 会话过期、Workspace
/// 还不存在、主机版本太老 —— 都掉进裸 `catch`，变成一句没有原因的
/// 「设备列表暂时不可用。」。星图上的表现是每个 Eidolon 的身体卫星都写「读不到」：
/// 真话，但把唯一有用的东西（为什么）擦掉了。
///
/// 所以这里断言的是**平面与它的异常类型绑在一起**，而不是某一句措辞：一个仓库方法
/// 走哪个面，是可以从源码读出来的事实，下一次迁移不该再靠人记得改 catch。
void main() {
  final repositories = File(
    'lib/src/features/host_setup/host_product_repositories.dart',
  ).readAsStringSync();
  final controller = File(
    'lib/src/features/host_setup/host_product_controller.dart',
  ).readAsStringSync();

  /// 一个方法的**声明**体，粗切到下一个声明为止。
  ///
  /// 找声明而不是找名字：第一次出现 `_loadDevices` 的地方是它的调用点，从那里往下
  /// 切会切到隔壁方法 —— 这条闸的第一版就是这么"通过"的，而它当时什么都没有守住。
  String _method(String source, String name) {
    // 逐行找声明行：返回类型里可能有嵌套的尖括号（Future<Map<String, Object?>>），
    // 用「不含 >」的模式去匹配返回类型，只会漏掉正好需要守住的那些。
    final declaration =
        RegExp('^\\s+(Future|void)[^\\n]*[ .]$name\\(', multiLine: true);
    final match = declaration.firstMatch(source);
    if (match == null) return '';
    final start = match.start;
    final next = source.indexOf('\n  Future<', start + 1);
    final alt = source.indexOf('\n  String ', start + 1);
    final end = [next, alt].where((i) => i > 0).fold<int>(
          source.length,
          (best, i) => i < best ? i : best,
        );
    return source.substring(start, end);
  }

  test('走管理面的读取，其错误处理必须认得管理面的拒绝', () {
    // 今天走管理面的读，和读它的那个控制器方法。
    const managed = <String, String>{
      'fetchMountedDevices': '_loadDevices',
      'missionControlSnapshot': 'missionControlSnapshot',
      'context': '_loadCapabilities',
    };

    for (final entry in managed.entries) {
      final repository = _method(repositories, entry.key);
      expect(
        repository.contains('executeManagement'),
        isTrue,
        reason: '${entry.key} 不再走管理面？那这张表要跟着改',
      );
      final reader = _method(controller, entry.value);
      if (reader.isEmpty || !reader.contains('try {')) continue;
      // 要么认得管理面的拒绝，要么像 _loadCapabilities 那样有明写的吞掉理由。
      final handles = reader.contains('ManagementRequestException');
      final deliberate = reader.contains('Swallowed on purpose') ||
          controller.contains('/// Swallowed on purpose');
      expect(
        handles || deliberate,
        isTrue,
        reason: '${entry.value} 读的是管理面，却不认得 ManagementRequestException',
      );
    }
  });

  test('走管理面的读取，不许用擦掉原因的 catch 收尾', () {
    // `catch (_)` 丢掉的正是唯一有用的东西。要么说出它是什么，要么别接。
    final devices = _method(controller, '_loadDevices');
    expect(devices.contains('} catch (_) {'), isFalse);
    expect(devices.contains(r'$error'), isTrue);
  });
}
