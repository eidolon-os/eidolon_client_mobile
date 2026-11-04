import 'package:flutter/material.dart';

/// One network a device (or a Host) can see.
class WifiNetworkChoice {
  const WifiNetworkChoice({
    required this.ssid,
    required this.secured,
    this.detail,
  });

  final String ssid;
  final bool secured;

  /// A short second line: the security mode, or how strong the signal is.
  final String? detail;
}

/// A list of networks where the password is typed under the network it is for.
///
/// Tapping a network opens it in place; only one is open at a time. The old
/// forms put one password field under the whole list, beside a hidden-network
/// field that was always there, so the password sat apart from the network it
/// belonged to and a person could type it with nothing chosen. Here an open
/// network needs no password at all and goes straight to its button, and a
/// network that is not in the list is the last row rather than a field that
/// competes with every row above it.
///
/// The picker owns no state a caller has to reconcile: which row is open, the
/// password and the hidden name all live in the caller, which already decides
/// what submitting means.
class WifiNetworkPicker extends StatefulWidget {
  const WifiNetworkPicker({
    super.key,
    required this.networks,
    required this.selectedSsid,
    required this.hiddenSelected,
    required this.onSelect,
    required this.onSelectHidden,
    required this.passwordController,
    required this.hiddenSsidController,
    required this.onSubmit,
    required this.submitLabel,
    required this.passwordFieldKey,
    required this.submitButtonKey,
    this.busy = false,
    this.allowHidden = true,
    this.currentSsid,
    this.onKeepCurrent,
  });

  final List<WifiNetworkChoice> networks;

  /// The open row, or null when no listed network is open.
  final String? selectedSsid;

  /// Whether the "other network" row is open.
  final bool hiddenSelected;

  /// A listed row was tapped: its SSID to open it, null to close the open one.
  final ValueChanged<String?> onSelect;

  /// The "other network" row was tapped: true to open it, false to close it.
  final ValueChanged<bool> onSelectHidden;

  final TextEditingController passwordController;
  final TextEditingController hiddenSsidController;
  final VoidCallback onSubmit;
  final String submitLabel;
  final Key passwordFieldKey;
  final Key submitButtonKey;
  final bool busy;
  final bool allowHidden;

  /// The network the device is already on. Its row continues without a
  /// password, because there is nothing to change.
  final String? currentSsid;
  final VoidCallback? onKeepCurrent;

  @override
  State<WifiNetworkPicker> createState() => _WifiNetworkPickerState();
}

class _WifiNetworkPickerState extends State<WifiNetworkPicker> {
  bool _showPassword = false;

  @override
  void didUpdateWidget(WifiNetworkPicker oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A password is shown only for the row it was revealed on.
    if (oldWidget.selectedSsid != widget.selectedSsid ||
        oldWidget.hiddenSelected != widget.hiddenSelected) {
      _showPassword = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final current = widget.currentSsid;
    final rows = <Widget>[
      if (current != null && widget.onKeepCurrent != null)
        _currentRow(context, current),
      for (final network in widget.networks)
        if (network.ssid != current || widget.onKeepCurrent == null)
          _networkRow(context, network),
      if (widget.allowHidden) _hiddenRow(context),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final row in rows) ...[row, const SizedBox(height: 8)],
      ],
    );
  }

  Widget _currentRow(BuildContext context, String ssid) => Card(
        margin: EdgeInsets.zero,
        child: ListTile(
          key: Key('network-current-$ssid'),
          leading:
              Icon(Icons.wifi, color: Theme.of(context).colorScheme.primary),
          title: Text(ssid),
          subtitle: const Text('保持当前网络'),
          trailing: const Icon(Icons.chevron_right),
          onTap: widget.busy ? null : widget.onKeepCurrent,
        ),
      );

  Widget _networkRow(BuildContext context, WifiNetworkChoice network) {
    final open = widget.selectedSsid == network.ssid && !widget.hiddenSelected;
    return Card(
      margin: EdgeInsets.zero,
      shape: _shape(context, open),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListTile(
            key: Key('network-${network.ssid}'),
            selected: open,
            leading: Icon(network.secured ? Icons.wifi_password : Icons.wifi),
            title: Text(network.ssid),
            subtitle: network.detail == null ? null : Text(network.detail!),
            trailing: Icon(open ? Icons.expand_less : Icons.expand_more),
            onTap: widget.busy
                ? null
                : () => widget.onSelect(open ? null : network.ssid),
          ),
          if (open)
            _panel(
              context,
              children: [
                if (network.secured) _passwordField(network.ssid),
              ],
            ),
        ],
      ),
    );
  }

  Widget _hiddenRow(BuildContext context) {
    final open = widget.hiddenSelected;
    return Card(
      margin: EdgeInsets.zero,
      shape: _shape(context, open),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListTile(
            key: const Key('network-hidden'),
            selected: open,
            leading: const Icon(Icons.add),
            title: Text(widget.networks.isEmpty ? '输入网络名称' : '其他网络'),
            subtitle: const Text('不在列表里的网络，或隐藏网络'),
            trailing: Icon(open ? Icons.expand_less : Icons.expand_more),
            onTap: widget.busy ? null : () => widget.onSelectHidden(!open),
          ),
          if (open)
            _panel(
              context,
              children: [
                TextField(
                  key: const Key('hidden-network-ssid'),
                  controller: widget.hiddenSsidController,
                  enabled: !widget.busy,
                  autofocus: true,
                  textInputAction: TextInputAction.next,
                  decoration: const InputDecoration(
                    labelText: 'Wi-Fi 名称',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                _passwordField(null, optional: true),
              ],
            ),
        ],
      ),
    );
  }

  ShapeBorder _shape(BuildContext context, bool open) => RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: open
            ? BorderSide(color: Theme.of(context).colorScheme.primary)
            : BorderSide.none,
      );

  Widget _panel(BuildContext context, {required List<Widget> children}) =>
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ...children,
            if (children.isNotEmpty) const SizedBox(height: 12),
            FilledButton(
              key: widget.submitButtonKey,
              onPressed: widget.busy ? null : widget.onSubmit,
              child: Text(widget.submitLabel),
            ),
          ],
        ),
      );

  Widget _passwordField(String? ssid, {bool optional = false}) => TextField(
        key: widget.passwordFieldKey,
        controller: widget.passwordController,
        enabled: !widget.busy,
        autofocus: ssid != null,
        obscureText: !_showPassword,
        enableSuggestions: false,
        autocorrect: false,
        textInputAction: TextInputAction.go,
        onSubmitted: (_) => widget.onSubmit(),
        decoration: InputDecoration(
          labelText: optional ? 'Wi-Fi 密码（开放网络留空）' : 'Wi-Fi 密码',
          hintText: ssid == null ? null : '$ssid 的密码',
          border: const OutlineInputBorder(),
          suffixIcon: IconButton(
            tooltip: _showPassword ? '隐藏密码' : '显示密码',
            onPressed: () => setState(() => _showPassword = !_showPassword),
            icon: Icon(_showPassword ? Icons.visibility_off : Icons.visibility),
          ),
        ),
      );
}
