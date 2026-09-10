import 'package:flutter/material.dart';
import '../generated/management_v1.dart';

class ConversationPreferencesForm extends StatelessWidget {
  const ConversationPreferencesForm(
      {super.key, required this.value, required this.onChanged});
  final ConversationPreferences value;
  final ValueChanged<ConversationPreferences> onChanged;

  void change({String? length, String? advice, String? followUp}) =>
      onChanged(ConversationPreferences(
        responseLength: length ?? value.responseLength ?? 'brief',
        advice: advice ?? value.advice ?? 'when_asked',
        followUp: followUp ?? value.followUp ?? 'when_needed',
      ));

  @override
  Widget build(BuildContext context) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('回复详略'),
        Wrap(spacing: 8, children: [
          for (final item in [
            ('brief', '简短'),
            ('balanced', '适中'),
            ('detailed', '详细')
          ])
            ChoiceChip(
                label: Text(item.$2),
                selected: (value.responseLength ?? 'brief') == item.$1,
                onSelected: (_) => change(length: item.$1)),
        ]),
        SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('主动给建议'),
            subtitle: const Text('关闭后，在你需要时再给建议'),
            value: value.advice == 'proactive',
            onChanged: (v) => change(advice: v ? 'proactive' : 'when_asked')),
        SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('主动延伸话题'),
            subtitle: const Text('关闭后，只在需要澄清时追问'),
            value: value.followUp == 'conversational',
            onChanged: (v) =>
                change(followUp: v ? 'conversational' : 'when_needed')),
      ]);
}
