import 'package:eidolon_client_mobile/src/features/host_setup/host_vitals_models.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _document(List<Map<String, dynamic>> vitals) => {
  'operation': 'local.host-vitals',
  'contract_version': '1',
  'observed_at': '2026-08-18T02:00:00Z',
  'vitals': vitals,
};

void main() {
  test('a reading the Host could not take is its own state', () {
    final vitals = HostVitals.fromJson(
      _document([
        {
          'name': '内存',
          'reading': '读不到',
          'concern': 'none',
          'unavailable_reason': '/proc/meminfo: absent',
        },
      ]),
    );

    final memory = vitals.vitals.single;
    // Not fine, not alarming — unknown. The screen draws it with its own mark
    // rather than a green tick, because a tick would claim the machine is
    // healthy on exactly the evidence we do not have.
    expect(memory.isUnavailable, isTrue);
    expect(memory.concern, VitalConcern.none);
    expect(memory.unavailableReason, contains('/proc/meminfo'));
  });

  test('what needs attention is what the Host said needs attention', () {
    final vitals = HostVitals.fromJson(
      _document([
        {'name': '存储空间', 'reading': '1.9 GB 可用，共 55.9 GB', 'concern': 'act'},
        {'name': '温度', 'reading': '72.5°C', 'concern': 'watch'},
        {'name': '已运行', 'reading': '1 天 2 小时', 'concern': 'none'},
      ]),
    );

    // No thresholds on this side. The same judgement in two places is two
    // judgements, and they drift.
    expect(
      vitals.needingAttention.map((vital) => vital.name),
      ['存储空间', '温度'],
    );
  });

  test('an unknown concern is read as none rather than refused', () {
    // A Host that grows a fourth level should not make an older App fail to
    // show the readings it does understand.
    final vitals = HostVitals.fromJson(
      _document([
        {'name': '温度', 'reading': '48.6°C', 'concern': 'something-new'},
      ]),
    );

    expect(vitals.vitals.single.concern, VitalConcern.none);
  });

  test('an answer that is not a v1 vitals document is refused', () {
    expect(
      () => HostVitals.fromJson({'operation': 'local.host-vitals'}),
      throwsFormatException,
    );
    expect(
      () => HostVitals.fromJson(_document([
        {'reading': '48.6°C'},
      ])),
      throwsFormatException,
    );
  });
}
