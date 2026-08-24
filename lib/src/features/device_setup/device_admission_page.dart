import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/material.dart';

import '../../generated/device_foundation_v1.dart';
import '../host_setup/host_product_session.dart';
import '../host_setup/local_api_client.dart';
import '../host_setup/pinned_http_client.dart';
import 'admission_projection.dart';

typedef EnrollmentRecoveryLoader = Future<EnrollmentProposalPageV1> Function({
  AdmissionListCursorV1? after,
});
typedef EnrollmentDecision = Future<EnrollmentRecoveryProjectionV1> Function({
  required String requestId,
  required EnrollmentRecoveryProjectionV1 projection,
});

class DeviceAdmissionPage extends StatefulWidget {
  const DeviceAdmissionPage({
    super.key,
    required this.ownerDomainId,
    required this.ownerDomainGeneration,
    required this.businessOwnerId,
    required this.controllerId,
    required this.loadRecovery,
    required this.onDecide,
  });

  final String ownerDomainId;
  final int ownerDomainGeneration;
  final String businessOwnerId;
  final String controllerId;
  final EnrollmentRecoveryLoader loadRecovery;
  final EnrollmentDecision onDecide;

  @override
  State<DeviceAdmissionPage> createState() => _DeviceAdmissionPageState();
}

class _DeviceAdmissionPageState extends State<DeviceAdmissionPage>
    with WidgetsBindingObserver {
  List<EnrollmentRecoveryProjectionV1> _items = const [];
  EnrollmentRecoveryProjectionV1? _selected;
  String? _error;
  var _busy = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !_busy) _load();
  }

  Future<void> _load() async {
    if (mounted) {
      setState(() {
        _busy = true;
        _error = null;
      });
    }
    try {
      final loaded = <EnrollmentRecoveryProjectionV1>[];
      AdmissionListCursorV1? cursor;
      do {
        final page = await widget.loadRecovery(after: cursor);
        for (final projection in page.projections) {
          projection.validateForOwner(
            widget.ownerDomainId,
            ownerDomainGeneration: widget.ownerDomainGeneration,
          );
          loaded.add(projection);
        }
        cursor = page.nextCursor;
      } while (cursor != null);
      if (!mounted) return;
      final selectedId = _selected?.proposal.json['enrollment_id'];
      setState(() {
        _items = List.unmodifiable(loaded);
        _selected = loaded
            .where((item) => item.proposal.json['enrollment_id'] == selectedId)
            .firstOrNull;
      });
    } catch (error) {
      if (mounted) setState(() => _error = _message(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _approve() async {
    final selected = _selected;
    if (_busy || selected == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final enrollmentId = selected.proposal.json['enrollment_id']! as String;
      final projection = await widget.onDecide(
        requestId: await _decisionRequestId(selected),
        projection: selected,
      );
      projection.validateForOwner(
        widget.ownerDomainId,
        ownerDomainGeneration: widget.ownerDomainGeneration,
      );
      if (!mounted) return;
      setState(() {
        _items = List.unmodifiable([
          for (final item in _items)
            if (item.proposal.json['enrollment_id'] == enrollmentId)
              projection
            else
              item,
        ]);
        _selected = projection;
      });
    } catch (error) {
      if (mounted) setState(() => _error = _message(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// A stable idempotency key for approving exactly this Proposal revision.
  ///
  /// Derived rather than random so that a reply lost mid-approval resumes the
  /// Host's one intent when the person taps again, and so that a Proposal that
  /// changed underneath the screen produces a different key instead of
  /// approving content nobody read.
  Future<String> _decisionRequestId(
    EnrollmentRecoveryProjectionV1 projection,
  ) async {
    final proposal = projection.proposal.json;
    final digest = await Sha256().hash(
      utf8.encode(
        '${widget.ownerDomainId}\n${widget.controllerId}\n'
        '${proposal['enrollment_id']}\n${projection.sourceRevision}',
      ),
    );
    return 'mobile-decision-${base64UrlEncode(digest.bytes).replaceAll('=', '')}';
  }

  String _message(Object error) => switch (error) {
        HostControllerAuthorizationException() => error.message,
        LocalApiRequestException() => error.toString(),
        PinnedHttpException() => '与主机的安全连接中断，请重新连接后恢复。',
        FormatException() => '主机返回的 Admission 投影未通过契约校验。',
        _ => '暂时无法读取或更新设备接入状态，请稍后恢复。',
      };

  @override
  Widget build(BuildContext context) => Scaffold(
        key: const Key('device-admission-page'),
        appBar: AppBar(
          title: const Text('设备接入'),
          actions: [
            IconButton(
              key: const Key('refresh-admission'),
              onPressed: _busy ? null : _load,
              tooltip: '刷新',
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              const Text(
                '配网、审批、Grant 交付和 Claim 生效是四个独立事实。',
                key: Key('admission-semantics'),
              ),
              if (_error case final error?) ...[
                const SizedBox(height: 16),
                Text(error, key: const Key('device-admission-error')),
              ],
              const SizedBox(height: 16),
              if (_busy)
                const Center(child: CircularProgressIndicator())
              else if (_items.isEmpty)
                const Card(
                  key: Key('no-admission-work'),
                  child: Padding(
                    padding: EdgeInsets.all(20),
                    child: Text('没有可见的 Enrollment；空列表不代表任何设备已经 ClaimActive。'),
                  ),
                )
              else
                ..._items.map(_tile),
              if (_selected case final selected?) ...[
                const SizedBox(height: 16),
                _DecisionContextCard(
                  projection: selected,
                  ownerDomainId: widget.ownerDomainId,
                  businessOwnerId: widget.businessOwnerId,
                  controllerId: widget.controllerId,
                ),
                const SizedBox(height: 12),
                if (selected.validateForOwner(
                      widget.ownerDomainId,
                      ownerDomainGeneration: widget.ownerDomainGeneration,
                    ) ==
                    AdmissionProjectionStage.pendingReview)
                  FilledButton(
                    key: const Key('confirm-enrollment-decision'),
                    onPressed: _busy ? null : _approve,
                    child: const Text('明确批准这次 Enrollment'),
                  ),
              ],
            ],
          ),
        ),
      );

  Widget _tile(EnrollmentRecoveryProjectionV1 projection) {
    final proposal = projection.proposal.json;
    final stage = projection.validateForOwner(
      widget.ownerDomainId,
      ownerDomainGeneration: widget.ownerDomainGeneration,
    );
    final enrollmentId = proposal['enrollment_id']! as String;
    final deviceId = proposal['device_instance_candidate_id']! as String;
    return Card(
      child: ListTile(
        key: Key('enrollment-$enrollmentId'),
        selected: _selected?.proposal.json['enrollment_id'] == enrollmentId,
        onTap: () => setState(() => _selected = projection),
        title: Text(deviceId),
        subtitle: Text(_stageLabel(stage)),
      ),
    );
  }
}

class _DecisionContextCard extends StatelessWidget {
  const _DecisionContextCard({
    required this.projection,
    required this.ownerDomainId,
    required this.businessOwnerId,
    required this.controllerId,
  });

  final EnrollmentRecoveryProjectionV1 projection;
  final String ownerDomainId;
  final String businessOwnerId;
  final String controllerId;

  @override
  Widget build(BuildContext context) {
    final proposal = projection.proposal.json;
    final manifest =
        Map<String, dynamic>.from(proposal['manifest_ref']! as Map);
    return Card(
      key: const Key('immutable-decision-context'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Text(
          'Actor：$controllerId\n'
          'Owner Domain：$ownerDomainId\n'
          'Business Owner：$businessOwnerId\n'
          'Enrollment：${proposal['enrollment_id']} @ revision '
          '${projection.sourceRevision}\n'
          'Manifest：${manifest['manifest_id']} @ ${manifest['revision']}\n'
          '批准不会宣称 Grant 已交付或 Claim 已生效。',
        ),
      ),
    );
  }
}

String _stageLabel(AdmissionProjectionStage stage) => switch (stage) {
      AdmissionProjectionStage.pendingReview => '待审批',
      AdmissionProjectionStage.approvedAwaitingHandoff => '已批准，等待设备领取 Grant',
      AdmissionProjectionStage.grantDelivered => 'Grant 已交付，等待 ClaimActive',
      AdmissionProjectionStage.claimActive => 'ClaimActive',
      AdmissionProjectionStage.rejected => '已拒绝',
      AdmissionProjectionStage.expired => '已过期',
      AdmissionProjectionStage.canceled => '已取消',
      AdmissionProjectionStage.claimRevoked => 'Claim 已撤销',
    };
