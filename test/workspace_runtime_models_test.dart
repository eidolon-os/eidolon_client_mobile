import 'package:eidolon_client_mobile/src/features/host_setup/workspace_runtime_models.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/workspace_models.dart';
import 'package:flutter_test/flutter_test.dart';

const _operationId = '32c421a3-e0df-40f9-8f75-68745ae39d81';

Map<String, dynamic> _validRuntime() => {
      'contract_version': '1',
      'operation_id': _operationId,
      'state': 'ready',
      'owner': {
        'owner_id': 'owner-1',
        'display_name': 'Manson',
        'lifecycle_state': 'active',
      },
      'primary_companion': {
        'companion_id': 'companion-1',
        'lifecycle_state': 'active',
      },
      'persona': {
        'genome_id': 'genome-current',
        'version': 3,
        'lifecycle_state': 'committed',
        'schema_version': 'eidolon.persona_genome',
        'genome_hash': 'sha256:${'a' * 64}',
        'realizer_version': '1',
      },
      'memory_workspace': {
        'realm_id': 'realm-1',
        'lifecycle_state': 'active',
      },
    };

void main() {
  test('strictly parses the sanitized daily Workspace runtime projection', () {
    final runtime = WorkspaceRuntime.fromJson(_validRuntime());

    expect(runtime.operationId, _operationId);
    expect(runtime.owner.displayName, 'Manson');
    expect(runtime.primaryCompanion.companionId, 'companion-1');
    expect(runtime.persona.version, 3);
    expect(runtime.memoryWorkspace.realmId, 'realm-1');
  });

  test('rejects unknown fields and inconsistent lifecycle values', () {
    final unknown = _validRuntime()..['raw_runtime_config'] = {};
    expect(
      () => WorkspaceRuntime.fromJson(unknown),
      throwsA(isA<FormatException>()),
    );

    final inactive = _validRuntime();
    (inactive['primary_companion'] as Map<String, dynamic>)['lifecycle_state'] =
        'inactive';
    expect(
      () => WorkspaceRuntime.fromJson(inactive),
      throwsA(isA<FormatException>()),
    );
  });

  test('matches only the same Workspace operation, Owner and Companion', () {
    final runtime = WorkspaceRuntime.fromJson(_validRuntime());
    final workspace = WorkspaceStatus.fromJson({
      'contract_version': '1',
      'operation_id': _operationId,
      'state': 'ready',
      'owner': {
        'owner_id': 'owner-1',
        'display_name': 'Manson',
        'lifecycle_state': 'active',
      },
      'workspace': {
        'state': 'ready',
        'primary_companion_id': 'companion-1',
        'persona_genome_id': 'genome-origin',
        'memory_realm_id': 'realm-1',
      },
    });
    expect(runtime.matchesWorkspace(workspace), isTrue);

    final crossOwner = _validRuntime();
    (crossOwner['owner'] as Map<String, dynamic>)['owner_id'] = 'owner-other';
    expect(
      WorkspaceRuntime.fromJson(crossOwner).matchesWorkspace(workspace),
      isFalse,
    );
  });

  group('the name its Owner gave this Eidolon', () {
    test('is read when the Host can say it', () {
      final companion = PrimaryCompanionRuntime.fromJson({
        'companion_id': 'c_683f963f54885e86892416894c9d92d1',
        'display_name': '小忆',
        'lifecycle_state': 'active',
      });

      expect(companion.displayName, '小忆');
    });

    test('is absent, not invented, on a Host that predates it', () {
      // An App is routinely newer than the Host beside it. The older document
      // has to parse, and what is missing stays missing — showing an
      // identifier where a name belongs is the thing this exists to stop.
      final companion = PrimaryCompanionRuntime.fromJson({
        'companion_id': 'c_683f963f54885e86892416894c9d92d1',
        'lifecycle_state': 'active',
      });

      expect(companion.displayName, isEmpty);
      expect(companion.companionId, 'c_683f963f54885e86892416894c9d92d1');
    });

    test('a shape the Host is not supposed to send is still refused', () {
      expect(
        () => PrimaryCompanionRuntime.fromJson({
          'companion_id': 'c_1',
          'display_name': 42,
          'lifecycle_state': 'active',
        }),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => PrimaryCompanionRuntime.fromJson({
          'companion_id': 'c_1',
          'display_name': '小忆',
          'lifecycle_state': 'active',
          'unexpected': true,
        }),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
