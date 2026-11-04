import 'package:eidolon_client_mobile/src/widgets/wifi_network_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Holds the picker's state the way the setup pages do.
class _Harness extends StatefulWidget {
  const _Harness({this.busy = false, this.currentSsid});

  final bool busy;
  final String? currentSsid;

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  final password = TextEditingController();
  final hidden = TextEditingController();
  String? selected;
  bool hiddenOpen = false;
  final submitted = <String>[];
  int kept = 0;

  final networks = const [
    WifiNetworkChoice(ssid: 'home', secured: true, detail: 'wpa2'),
    WifiNetworkChoice(ssid: 'cafe', secured: false, detail: 'open'),
  ];

  @override
  Widget build(BuildContext context) => MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: WifiNetworkPicker(
              networks: networks,
              selectedSsid: hiddenOpen ? null : selected,
              hiddenSelected: hiddenOpen,
              onSelect: (ssid) => setState(() {
                selected = ssid;
                hiddenOpen = false;
                password.clear();
              }),
              onSelectHidden: (open) => setState(() {
                hiddenOpen = open;
                selected = null;
              }),
              passwordController: password,
              hiddenSsidController: hidden,
              onSubmit: () => submitted.add(
                  '${hiddenOpen ? hidden.text : selected}:${password.text}'),
              submitLabel: '连接',
              passwordFieldKey: const Key('password'),
              submitButtonKey: const Key('submit'),
              busy: widget.busy,
              currentSsid: widget.currentSsid,
              onKeepCurrent: () => kept++,
            ),
          ),
        ),
      );
}

void main() {
  testWidgets('the password is typed under the network it is for',
      (tester) async {
    await tester.pumpWidget(const _Harness());
    expect(find.byKey(const Key('password')), findsNothing);
    expect(find.byKey(const Key('submit')), findsNothing);

    await tester.tap(find.byKey(const Key('network-home')));
    await tester.pump();
    expect(
        tester.widget<ListTile>(find.byKey(const Key('network-home'))).selected,
        isTrue);
    await tester.enterText(find.byKey(const Key('password')), 'secret-1');
    await tester.tap(find.byKey(const Key('submit')));
    final state = tester.state<_HarnessState>(find.byType(_Harness));
    expect(state.submitted, ['home:secret-1']);
  });

  testWidgets('one network is open at a time, and moving on drops the password',
      (tester) async {
    await tester.pumpWidget(const _Harness());
    await tester.tap(find.byKey(const Key('network-home')));
    await tester.pump();
    await tester.enterText(find.byKey(const Key('password')), 'secret-1');
    await tester.tap(find.byKey(const Key('network-cafe')));
    await tester.pump();
    expect(
        tester.widget<ListTile>(find.byKey(const Key('network-home'))).selected,
        isFalse);
    // An open network asks for nothing but the button.
    expect(find.byKey(const Key('password')), findsNothing);
    expect(find.byKey(const Key('submit')), findsOneWidget);
    await tester.tap(find.byKey(const Key('submit')));
    expect(tester.state<_HarnessState>(find.byType(_Harness)).submitted,
        ['cafe:']);
  });

  testWidgets(
      'a network that is not listed is the last row, with its own name field',
      (tester) async {
    await tester.pumpWidget(const _Harness());
    await tester.tap(find.byKey(const Key('network-hidden')));
    await tester.pump();
    await tester.enterText(
        find.byKey(const Key('hidden-network-ssid')), 'attic');
    await tester.enterText(find.byKey(const Key('password')), 'secret-2');
    await tester.tap(find.byKey(const Key('submit')));
    expect(tester.state<_HarnessState>(find.byType(_Harness)).submitted,
        ['attic:secret-2']);
  });

  testWidgets(
      'the network the device is already on continues without a password',
      (tester) async {
    await tester.pumpWidget(const _Harness(currentSsid: 'home'));
    // Listed once, as the current network, not twice.
    expect(find.text('home'), findsOneWidget);
    await tester.tap(find.byKey(const Key('network-current-home')));
    await tester.pump();
    expect(find.byKey(const Key('password')), findsNothing);
    expect(tester.state<_HarnessState>(find.byType(_Harness)).kept, 1);
  });

  testWidgets('nothing can be opened or submitted while busy', (tester) async {
    await tester.pumpWidget(const _Harness(busy: true));
    await tester.tap(find.byKey(const Key('network-home')));
    await tester.pump();
    expect(find.byKey(const Key('password')), findsNothing);
  });
}
