/// One sentence about this Host, and the things that make it not "fine".
///
/// This is the piece the three screens it replaces did not have. 运行驾驶舱,
/// 主机动态 and 查看系统状态 each drew every fact it could read at full size,
/// always — so finding out whether anything was wrong meant reading three
/// screens end to end and noticing an absence. The reader's question is not
/// "what are all the readings", it is **"它还好吗，哪里不对，我能动什么"**.
///
/// So: a verdict computed from the same reads the rows are drawn from — it
/// cannot disagree with them — plus the deviations, each with the reason and,
/// where there is one, the thing that can be done about it. On a healthy Host
/// this is one line and nothing else.
///
/// Two rules it holds:
///
/// * **the Host's judgement is not re-decided here.** ``VitalConcern`` is
///   assigned Host-side; a disk at 91% is a concern because the Host said so,
///   not because this file picked 90. Re-deciding it in the app is how two
///   screens end up disagreeing about the same disk;
/// * **unreadable is a concern of its own.** A source that could not be read is
///   not a healthy one, and it is not a broken Host either. It gets its own
///   line, because "I could not tell" is a different thing to act on than
///   "this is down".
library;

import 'host_service_models.dart';
import 'host_vitals_models.dart';

/// How loud the verdict is. `act` outranks `watch` outranks `unknown`.
enum HostConcernLevel { none, unknown, watch, act }

/// One thing that keeps this Host from reading as fine.
class HostConcern {
  const HostConcern({
    required this.level,
    required this.what,
    required this.why,
    this.serviceId,
  });

  final HostConcernLevel level;

  /// The thing itself, in the words a person uses: 「记忆服务」, 「磁盘」.
  final String what;

  /// Why it is here. The upstream's own words where there are any.
  final String why;

  /// Set when this concern has something the reader can do about it right
  /// here — today only a service, which can be restarted from its own row.
  final String? serviceId;
}

class HostVerdict {
  const HostVerdict(
      {required this.level, required this.headline, required this.concerns});

  final HostConcernLevel level;

  /// The one line at the top. It says the state, not the readings.
  final String headline;

  /// Worst first, so the line under the headline is the one worth reading.
  final List<HostConcern> concerns;

  bool get fine => level == HostConcernLevel.none;
}

/// The verdict, from everything this page read.
///
/// Nulls mean "not read yet"; a non-null failure string means "could not be
/// read". Those are different states and neither is 正常 — see
/// [HostConcernLevel.unknown].
HostVerdict hostVerdict({
  HostVitals? vitals,
  String? vitalsFailure,
  HostServiceInventory? services,
  String? servicesFailure,
  String? devicesFailure,
  String? activityFailure,
  String? controllersFailure,
}) {
  final concerns = <HostConcern>[];

  for (final vital in vitals?.needingAttention ?? const <HostVital>[]) {
    concerns.add(
      HostConcern(
        level: vital.concern == VitalConcern.act
            ? HostConcernLevel.act
            : HostConcernLevel.watch,
        what: vital.name,
        why: vital.reading,
      ),
    );
  }
  for (final vital in vitals?.vitals ?? const <HostVital>[]) {
    if (vital.isUnavailable) {
      concerns.add(
        HostConcern(
          level: HostConcernLevel.unknown,
          what: vital.name,
          why: vital.unavailableReason ?? '读不到',
        ),
      );
    }
  }

  for (final service in services?.services ?? const <HostService>[]) {
    final level = _serviceLevel(service);
    if (level == HostConcernLevel.none) continue;
    concerns.add(
      HostConcern(
        level: level,
        // The wire carries no display name for a service, only its id — and an
        // id is what an operator restarts, so it is also the right word here.
        what: service.serviceId,
        why: service.detail?.isNotEmpty == true
            ? service.detail!
            : hostServiceStateLabel(service.runtimeState),
        // Only a service carries an action, and only where the Host offered
        // one. The row it belongs to is where the button goes.
        serviceId: service.serviceId,
      ),
    );
  }

  for (final (what, failure) in <(String, String?)>[
    ('机器读数', vitalsFailure),
    ('底座', servicesFailure),
    ('设备', devicesFailure),
    ('最近的改动', activityFailure),
    ('管理这台主机的手机', controllersFailure),
  ]) {
    if (failure == null) continue;
    concerns.add(
      HostConcern(level: HostConcernLevel.unknown, what: what, why: failure),
    );
  }

  concerns.sort((a, b) => b.level.index.compareTo(a.level.index));
  final level = concerns.isEmpty ? HostConcernLevel.none : concerns.first.level;
  return HostVerdict(
    level: level,
    headline: _headline(level, concerns.length),
    concerns: concerns,
  );
}

/// A required service that is not running is the loudest thing on this screen;
/// an optional one that is off was probably turned off on purpose.
HostConcernLevel _serviceLevel(HostService service) {
  switch (service.runtimeState) {
    case HostServiceRuntimeState.failed:
    case HostServiceRuntimeState.blocked:
      return service.required ? HostConcernLevel.act : HostConcernLevel.watch;
    case HostServiceRuntimeState.degraded:
      return HostConcernLevel.watch;
    case HostServiceRuntimeState.inactive:
      // Disabled on purpose is not a concern. Required-but-inactive is.
      return service.required && service.enabled
          ? HostConcernLevel.act
          : HostConcernLevel.none;
    case HostServiceRuntimeState.unknown:
      // A state this version has never heard of. Not fine, not broken.
      return HostConcernLevel.unknown;
    case HostServiceRuntimeState.starting:
    case HostServiceRuntimeState.ready:
      return HostConcernLevel.none;
  }
}

String _headline(HostConcernLevel level, int count) => switch (level) {
      HostConcernLevel.none => '这台主机一切正常',
      HostConcernLevel.unknown => '有 $count 项读不到，状态未知',
      HostConcernLevel.watch => '有 $count 项要留意',
      HostConcernLevel.act => '有 $count 项需要处理',
    };
