import '../../generated/management_v1.dart';
import '../host_setup/host_product_session.dart';

/// Uses the existing authenticated Host session, never a page-owned credential.
class TeamRepository {
  TeamRepository(this._session);
  final HostProductSession _session;

  Future<TeamPage> list({String? after}) =>
      _session.executeManagement((client, uri, token) =>
          client.fetchTeams(uri, accessToken: token, after: after));

  Future<TeamConflicts> conflicts(String id) =>
      _session.executeManagement((client, uri, token) =>
          client.fetchTeamConflicts(uri, accessToken: token, teamId: id));

  Future<TeamStarts> runs(String id) =>
      _session.executeManagement((client, uri, token) =>
          client.fetchTeamRuns(uri, accessToken: token, teamId: id));

  Future<TeamRevision> get(String id) =>
      _session.executeManagement((client, uri, token) =>
          client.fetchTeam(uri, accessToken: token, teamId: id));

  Future<TeamRevision> save(
          String id, int revision, TeamConfiguration configuration) =>
      _session.executeManagement((client, uri, token) => client.saveTeam(uri,
          accessToken: token,
          teamId: id,
          expectedRevision: revision,
          configuration: configuration));

  Future<void> delete(String id, int revision) =>
      _session.executeManagement((client, uri, token) => client.deleteTeam(uri,
          accessToken: token, teamId: id, expectedRevision: revision));
}
