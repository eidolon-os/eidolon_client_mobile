import 'package:flutter/material.dart';

import '../generated/management_v1.dart';
import 'authoring_lines.dart';

/// The fields that say who an Eidolon is, in one place.
///
/// Two screens ask for them and they must ask for the same things: creating one
/// walks somebody through in four steps, editing one puts everything on a page
/// they can scroll to. If each owned its own copy of the field list, a field
/// added later would land in one of them and the other would silently drop it
/// on the next save.
///
/// The grouping is the one the Admin web page used before it was removed, and
/// it is kept because it was already right: who TA is, what you two are to each
/// other, how TA comes across. Two screens using different groupings would be
/// two mental models of the same Eidolon.
class PersonaForm {
  PersonaForm(PersonaAuthoring standing)
      : _standing = standing,
        selfConcept = TextEditingController(text: standing.selfConcept ?? ''),
        characterPortrait =
            TextEditingController(text: standing.characterPortrait ?? ''),
        relationshipNarrative =
            TextEditingController(text: standing.relationshipNarrative ?? ''),
        voicePortrait =
            TextEditingController(text: standing.voicePortrait ?? ''),
        values = [...?standing.values],
        boundaries = [...?standing.boundaries],
        commitments = [...?standing.commitments],
        pinnedFacts = [...?standing.pinnedFacts],
        safetyBoundaries = [...?standing.safetyBoundaries],
        behaviorGuidance = [...?standing.behaviorGuidance],
        dialogueExamples = [...?standing.dialogueExamples];

  /// What it was when the form opened. Kept so the form can tell whether
  /// anything actually changed, and so the fields it does not show travel back
  /// unharmed rather than being wiped by their own absence.
  final PersonaAuthoring _standing;

  final TextEditingController selfConcept;
  final TextEditingController characterPortrait;
  final TextEditingController relationshipNarrative;
  final TextEditingController voicePortrait;

  List<String> values;
  List<String> boundaries;
  List<String> commitments;
  List<String> pinnedFacts;
  List<String> safetyBoundaries;
  List<String> behaviorGuidance;
  List<String> dialogueExamples;

  void dispose() {
    selfConcept.dispose();
    characterPortrait.dispose();
    relationshipNarrative.dispose();
    voicePortrait.dispose();
  }

  /// Everything as it now stands.
  ///
  /// `archetype`, `traits` and `modality_notes` ride along untouched: they are
  /// part of who this Eidolon is but not part of what a person writes, and
  /// leaving them out would let an edit to one sentence erase them.
  PersonaAuthoring get authoring => PersonaAuthoring(
        archetype: _standing.archetype,
        selfConcept: selfConcept.text.trim(),
        characterPortrait: characterPortrait.text.trim(),
        relationshipNarrative: relationshipNarrative.text.trim(),
        voicePortrait: voicePortrait.text.trim(),
        values: values,
        boundaries: boundaries,
        commitments: commitments,
        pinnedFacts: pinnedFacts,
        safetyBoundaries: safetyBoundaries,
        behaviorGuidance: behaviorGuidance,
        dialogueExamples: dialogueExamples,
        modalityNotes: _standing.modalityNotes,
        traits: _standing.traits,
      );

  /// Whether anything on the form differs from what it opened on.
  bool get unchanged {
    bool sameLines(List<String>? mine, List<String>? theirs) {
      final a = mine ?? const <String>[];
      final b = theirs ?? const <String>[];
      if (a.length != b.length) return false;
      for (var index = 0; index < a.length; index++) {
        if (a[index] != b[index]) return false;
      }
      return true;
    }

    return selfConcept.text.trim() == (_standing.selfConcept ?? '') &&
        characterPortrait.text.trim() == (_standing.characterPortrait ?? '') &&
        relationshipNarrative.text.trim() ==
            (_standing.relationshipNarrative ?? '') &&
        voicePortrait.text.trim() == (_standing.voicePortrait ?? '') &&
        sameLines(values, _standing.values) &&
        sameLines(boundaries, _standing.boundaries) &&
        sameLines(commitments, _standing.commitments) &&
        sameLines(pinnedFacts, _standing.pinnedFacts) &&
        sameLines(safetyBoundaries, _standing.safetyBoundaries) &&
        sameLines(behaviorGuidance, _standing.behaviorGuidance) &&
        sameLines(dialogueExamples, _standing.dialogueExamples);
  }

  /// 「TA 是谁」— what it thinks it is, and what it will not do.
  List<Widget> whoItIs(VoidCallback changed) => [
        AuthoringProse(
          fieldKey: const Key('authoring-self-concept'),
          label: '自我认知',
          help: 'TA 认为自己是什么。用 TA 的口吻写。',
          controller: selfConcept,
        ),
        const SizedBox(height: 24),
        AuthoringProse(
          fieldKey: const Key('authoring-character-portrait'),
          label: '人格画像',
          help: '别人会怎么形容 TA。',
          controller: characterPortrait,
          minLines: 4,
        ),
        const SizedBox(height: 24),
        AuthoringLines(
          fieldKey: const Key('authoring-values'),
          label: '价值观',
          help: 'TA 长期坚持的东西。',
          hint: '一条长期坚持的价值',
          lines: values,
          onChanged: (lines) {
            values = lines;
            changed();
          },
        ),
        const SizedBox(height: 24),
        AuthoringLines(
          fieldKey: const Key('authoring-boundaries'),
          label: '不可突破的边界',
          help: 'TA 无论如何都不会做的事。',
          hint: '一条绝不跨过的边界',
          lines: boundaries,
          onChanged: (lines) {
            boundaries = lines;
            changed();
          },
        ),
      ];

  /// 「你们的关系」— what the two of you are to each other.
  List<Widget> theRelationship(VoidCallback changed) => [
        AuthoringProse(
          fieldKey: const Key('authoring-relationship'),
          label: '关系叙事',
          help: '你和 TA 是什么关系，从哪里开始的。',
          controller: relationshipNarrative,
          minLines: 4,
        ),
        const SizedBox(height: 24),
        AuthoringLines(
          fieldKey: const Key('authoring-commitments'),
          label: '关系承诺',
          help: 'TA 对这段关系许下的事。',
          hint: 'TA 对这段关系的一条承诺',
          lines: commitments,
          onChanged: (lines) {
            commitments = lines;
            changed();
          },
        ),
        const SizedBox(height: 24),
        AuthoringLines(
          fieldKey: const Key('authoring-pinned-facts'),
          label: '已确认事实',
          help: '关于你的、TA 一开始就该知道的事。',
          hint: '关于你已确认的事实',
          lines: pinnedFacts,
          onChanged: (lines) {
            pinnedFacts = lines;
            changed();
          },
        ),
        const SizedBox(height: 24),
        AuthoringLines(
          fieldKey: const Key('authoring-safety-boundaries'),
          label: '关系安全边界',
          help: '在你们之间始终要守住的东西。',
          hint: '在关系中需要始终遵守的边界',
          lines: safetyBoundaries,
          onChanged: (lines) {
            safetyBoundaries = lines;
            changed();
          },
        ),
      ];

  /// 「TA 如何表达」— how it comes across.
  List<Widget> howItSpeaks(VoidCallback changed) => [
        AuthoringProse(
          fieldKey: const Key('authoring-voice-portrait'),
          label: '表达画像',
          help: 'TA 说话是什么样的。',
          controller: voicePortrait,
          minLines: 4,
        ),
        const SizedBox(height: 24),
        AuthoringLines(
          fieldKey: const Key('authoring-behavior-guidance'),
          label: '行为引导',
          help: '看得出来的表达习惯。',
          hint: '一条可观察的表达习惯',
          lines: behaviorGuidance,
          onChanged: (lines) {
            behaviorGuidance = lines;
            changed();
          },
        ),
        const SizedBox(height: 24),
        AuthoringLines(
          fieldKey: const Key('authoring-dialogue-examples'),
          label: '典型对话示例',
          help: '一句能代表 TA 的话。',
          hint: '一段能代表 TA 的自然表达',
          lines: dialogueExamples,
          onChanged: (lines) {
            dialogueExamples = lines;
            changed();
          },
        ),
      ];
}
