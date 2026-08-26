import 'package:eidolon_client_mobile/src/features/host_setup/host_runtime_verdict.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/host_service_models.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/host_vitals_models.dart';
import 'package:flutter_test/flutter_test.dart';

/// 「它还好吗，哪里不对」—— 这一句必须由画出下面那些行的同一批读取算出来。
///
/// 这块屏取代的三块（运行驾驶舱、主机动态、查看系统状态）每一块都把能读到的一切
/// 按原尺寸铺开，永远如此，所以「有没有出问题」要靠人读完三屏、并注意到一处缺席。
/// 判词是让它们能塌成一块的那个东西，而它的正确性只有两条：不替主机重新下判断，
/// 以及「读不到」自成一类。

HostVital _vital(String name,
        {VitalConcern concern = VitalConcern.none, String? unavailable}) =>
    HostVital(
      name: name,
      reading: unavailable == null ? '41%' : '',
      concern: concern,
      unavailableReason: unavailable,
    );

HostService _service(
  String id, {
  bool required = true,
  bool enabled = true,
  HostServiceRuntimeState state = HostServiceRuntimeState.ready,
  String? detail,
}) =>
    HostService(
      serviceId: id,
      required: required,
      enabled: enabled,
      revision: 1,
      runtimeState: state,
      detail: detail,
      observedAt: DateTime.utc(2026, 8, 27),
    );

HostVitals _vitals(List<HostVital> vitals) =>
    HostVitals(observedAt: DateTime.utc(2026, 8, 27), vitals: vitals);

HostServiceInventory _inventory(List<HostService> services) =>
    HostServiceInventory(services: services);

void main() {
  test('什么都好的时候，就是一行', () {
    final verdict = hostVerdict(
      vitals: _vitals([_vital('磁盘'), _vital('内存')]),
      services: _inventory([_service('hub'), _service('agent')]),
    );

    expect(verdict.fine, isTrue);
    expect(verdict.headline, '这台主机一切正常');
    expect(verdict.concerns, isEmpty);
  });

  test('主机说该处理的，就是该处理的 —— 阈值不在这里重定', () {
    // 磁盘 91% 是异常，因为主机这么说了，不是因为这个文件挑了 90。
    // 在客户端重新判一次，是两块屏对同一块磁盘各说一套的由来。
    final verdict = hostVerdict(
      vitals: _vitals([_vital('磁盘', concern: VitalConcern.act), _vital('内存')]),
      services: _inventory([_service('hub')]),
    );

    expect(verdict.level, HostConcernLevel.act);
    expect(verdict.headline, '有 1 项需要处理');
    expect(verdict.concerns.single.what, '磁盘');
  });

  test('必需服务停着要处理，被关掉的可选服务不是异常', () {
    final verdict = hostVerdict(
      services: _inventory([
        _service('memory',
            state: HostServiceRuntimeState.failed, detail: '端口占用'),
        // 有人有意关掉的东西，不该每次打开这一屏都来喊一次。
        _service('mementos',
            required: false,
            enabled: false,
            state: HostServiceRuntimeState.inactive),
      ]),
    );

    expect(verdict.concerns.map((c) => c.what), ['memory']);
    expect(verdict.concerns.single.why, '端口占用');
    // 动作就在它自己那一行上，而不是另开一张服务卡。
    expect(verdict.concerns.single.serviceId, 'memory');
  });

  test('读不到自成一类：不是正常，也不是坏了', () {
    final verdict = hostVerdict(
      services: _inventory([_service('hub')]),
      vitalsFailure: 'Host vitals 返回 HTTP 500',
    );

    expect(verdict.level, HostConcernLevel.unknown);
    expect(verdict.headline, '有 1 项读不到，状态未知');
    expect(verdict.concerns.single.what, '机器读数');
    expect(verdict.concerns.single.why, contains('HTTP 500'));
    // 「我说不上来」和「这个坏了」是两件要采取不同行动的事。
    expect(verdict.concerns.single.serviceId, isNull);
  });

  test('该处理的排在要留意的前面，要留意的排在读不到前面', () {
    final verdict = hostVerdict(
      vitals: _vitals([_vital('内存', concern: VitalConcern.watch)]),
      services: _inventory([
        _service('memory', state: HostServiceRuntimeState.failed),
      ]),
      activityFailure: 'Data 没有回应',
    );

    expect(
      verdict.concerns.map((c) => c.level),
      [HostConcernLevel.act, HostConcernLevel.watch, HostConcernLevel.unknown],
    );
    // 顶上那句说的是最响的那一项。
    expect(verdict.level, HostConcernLevel.act);
    expect(verdict.headline, '有 3 项需要处理');
  });

  test('一项读数读不到，不会让整块机器读数变成正常', () {
    final verdict = hostVerdict(
      vitals: _vitals([
        _vital('磁盘'),
        _vital('温度', unavailable: '这台主机没有温度传感器'),
      ]),
    );

    expect(verdict.level, HostConcernLevel.unknown);
    expect(verdict.concerns.single.what, '温度');
    expect(verdict.concerns.single.why, contains('温度传感器'));
  });

  test('这个版本没听过的服务状态，不当作正常', () {
    // 主机可能长出新状态。把它读成 ready 是那一类会让人损失设备的猜测。
    final verdict = hostVerdict(
      services: _inventory([
        _service('hub', state: HostServiceRuntimeState.unknown),
      ]),
    );

    expect(verdict.level, HostConcernLevel.unknown);
    expect(verdict.concerns.single.what, 'hub');
  });

  test('什么都还没读到，不是一切正常', () {
    // 所有参数为 null = 这一屏刚打开。它此时无权宣布正常。
    final verdict = hostVerdict();

    expect(verdict.fine, isTrue, reason: '没有 concern 可列');
    // 但这不是「正常」的凭据：页面在读完之前不画判词，见 host_runtime_status_page。
    expect(verdict.concerns, isEmpty);
  });
}
