import 'package:eidolon_client_mobile/src/management/memory_labels.dart';
import 'package:flutter_test/flutter_test.dart';

/// Room names are the model's filing (Memory's "Room 命名规范"); what a person
/// sees is a category, never the slug. Seen on the Pad (11-04): 家里的记忆
/// listed `home_storage` and `preference_home`.
void main() {
  test('each kind of room is a category a person can read', () {
    expect(memoryRoomLabel('home_storage'), '家里的事');
    expect(memoryRoomLabel('household_schedule'), '家里的事');
    expect(memoryRoomLabel('preference_home'), '偏好');
    expect(memoryRoomLabel('preference_music'), '偏好');
    expect(memoryRoomLabel('profile_core'), '基本情况');
    expect(memoryRoomLabel('emotion_work_2026_11'), '心情');
    expect(memoryRoomLabel('event_trip'), '经历');
    expect(memoryRoomLabel('project_eidolon'), '项目');
    expect(memoryRoomLabel('privacy_health'), '封存的内容');
  });

  test('a topic a person can read is kept beside its category', () {
    expect(memoryRoomLabel('person_铁锤'), '人物 · 铁锤');
    expect(memoryRoomLabel('pet_小黑'), '宠物 · 小黑');
    expect(memoryRoomLabel('preference_喝茶'), '偏好 · 喝茶');
    expect(memoryRoomLabel('topic_周末_爬山'), '话题 · 周末 爬山');
    // Dates and the private parts of a room stay out of its name.
    expect(memoryRoomLabel('emotion_工作压力_2026_11'), '心情');
    expect(memoryRoomLabel('privacy_体检'), '封存的内容');
  });

  test('a slug nothing knows is never shown as it is', () {
    for (final room in ['chores', 'family_storage', 'general', 'Wing_Life']) {
      expect(memoryRoomLabel(room), '其他记忆', reason: room);
    }
    expect(memoryRoomLabel('客厅'), '客厅');
  });

  test('ingestion identifiers stay what they were', () {
    expect(memoryRoomLabel(''), '未分类记忆');
    expect(memoryRoomLabel('userconfirm_abc'), '已整理的记录');
    expect(memoryRoomLabel('turn:1234'), '对话中记下的');
    expect(memoryRoomLabel('room/0123456789abcdef'), '其他记忆');
  });
}
