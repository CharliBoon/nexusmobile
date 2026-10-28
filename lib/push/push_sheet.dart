import 'dart:async';

import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter/material.dart';

import 'nexus_push.dart';

class NexusPushSheet extends StatefulWidget {
  final String database;

  const NexusPushSheet({super.key, required this.database});

  static Future<void> show(BuildContext context, String database) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => NexusPushSheet(database: database),
    );
  }

  @override
  State<NexusPushSheet> createState() => _NexusPushSheetState();
}

const _spinnerColor = Color(0xFF0D2230);

class _NexusPushSheetState extends State<NexusPushSheet> {
  bool _busy = true;
  bool _registered = false;
  NexusRules _rules = NexusRules(rules: {}, chosen: {});
  Set<String> _chosen = {}; // what the user ticked, shown at once
  Set<String> _savedChosen = {}; // what the server has
  Timer? _saveTimer;
  bool _saving = false;
  bool _savePending = false;
  bool _closed = false;
  String? _rulesError;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadStatus();
  }

  @override
  void dispose() {
    _closed = true;
    _saveTimer?.cancel();

    // What was ticked in the last moment is still saved
    if (!setEquals(_chosen, _savedChosen)) _save();

    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      await action();
    } on NexusPushException catch (e) {
      _error = e.message;
    } catch (e) {
      debugPrint('Push sheet failed: $e');
      _error = 'Something went wrong. Please try again.';
    }

    if (mounted) {
      setState(() {
        _busy = false;
      });
    }
  }

  Future<void> _loadStatus() {
    return _run(() async {
      _registered = await NexusPush.instance.isRegistered(widget.database);
      _setRules(_registered
          ? await NexusPush.instance.fetchNotifications(widget.database)
          : NexusRules(rules: {}, chosen: {}));
    });
  }

  Future<void> _toggle() {
    return _run(() async {
      if (_registered) {
        await NexusPush.instance.unregister(widget.database);
        _setRules(NexusRules(rules: {}, chosen: {}));
      } else {
        await NexusPush.instance.register(widget.database);
        _setRules(await NexusPush.instance.fetchNotifications(widget.database));
      }
      _registered = !_registered;
    });
  }

  void _setRules(NexusRules rules) {
    _saveTimer?.cancel();
    _rules = rules;
    _chosen = Set<String>.of(rules.chosen);
    _savedChosen = Set<String>.of(rules.chosen);
  }

  // The ticks show at once and are saved in one call a moment after the last one,
  // so many rules can be ticked quickly without waiting for the server
  void _setChosen(Set<String> chosen) {
    setState(() {
      _chosen = chosen;
      _rulesError = null;
    });

    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 600), _save);
  }

  Future<void> _save() async {
    if (_saving) {
      _savePending = true; // saved again when the one that is busy is done
      return;
    }

    if (setEquals(_chosen, _savedChosen)) return;

    final toSave = Set<String>.of(_chosen);
    _saving = true;
    if (!_closed) setState(() {});

    try {
      await NexusPush.instance.selectNotifications(widget.database, toSave);
      _savedChosen = toSave;
    } on NexusPushException catch (e) {
      _failedToSave(e.message);
    } catch (e) {
      debugPrint('Could not save the notifications: $e');
      _failedToSave('Could not save your choice. Please try again.');
    }

    _saving = false;
    if (!_closed) setState(() {});

    if (_savePending) {
      _savePending = false;
      await _save();
    }
  }

  // The ticks go back to what the server has
  void _failedToSave(String message) {
    _chosen = Set<String>.of(_savedChosen);
    _savePending = false;
    _rulesError = message;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Material(
          color: theme.colorScheme.surfaceContainerHigh,
          elevation: 6,
          borderRadius: BorderRadius.circular(24),
          clipBehavior: Clip.antiAlias,
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: AnimatedSize(
              duration: const Duration(milliseconds: 200),
              alignment: Alignment.topCenter,
              child: _busy
                  ? _buildLoading(context)
                  : _error != null
                      ? _buildError(theme)
                      : _buildStatus(theme),
            ),
          ),
        ),
      ),
    );
  }

  // The whole card takes 18% of the screen height while it loads, 48 is its padding
  Widget _buildLoading(BuildContext context) {
    final height = MediaQuery.of(context).size.height * 0.18 - 48;

    return SizedBox(
      height: height < 96 ? 96 : height,
      child: const _LoadingPlaceholder(),
    );
  }

  Widget _buildStatus(ThemeData theme) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          _registered ? 'Notifications are on' : 'Notifications are off',
          style:
              theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 2),
        Text('for ${widget.database}', style: theme.textTheme.bodyMedium),
        if (_registered) ...[
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text(
              'Only IMS TARP notifications are available.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
          const SizedBox(height: 16),
          _buildRules(theme),
        ],
        const SizedBox(height: 20),
        _buildButton(_registered ? 'Turn off' : 'Turn on', _toggle),
      ],
    );
  }

  Widget _buildRules(ThemeData theme) {
    final rules = _rules.rules;

    if (rules.isEmpty) {
      return Text(
        'No notifications are available, please contact support@imsi.org for more information.',
        textAlign: TextAlign.center,
        style: theme.textTheme.bodyMedium,
      );
    }

    final ruleIds = rules.keys.toList()
      ..sort((a, b) => rules[a]!.toLowerCase().compareTo(rules[b]!.toLowerCase()));
    final allChosen = ruleIds.every(_chosen.contains);
    final noneChosen = ruleIds.every((id) => !_chosen.contains(id));
    final saving = _saving || !setEquals(_chosen, _savedChosen);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Choose what you receive',
            style: theme.textTheme.labelLarge
                ?.copyWith(fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        Stack(
          clipBehavior: Clip.none,
          children: [
            CheckboxListTile(
              dense: true,
              visualDensity: VisualDensity.compact,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              checkboxShape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(4)),
              tristate: true,
              title: const Text('Select all',
                  style: TextStyle(fontWeight: FontWeight.w600)),
              value: allChosen ? true : (noneChosen ? false : null),
              onChanged: (_) =>
                  _setChosen(allChosen ? <String>{} : ruleIds.toSet()),
            ),
            // In line with the right edge of the button, so nothing moves when it shows
            Positioned(
              right: 0,
              top: 0,
              bottom: 0,
              child: Center(
                child: AnimatedOpacity(
                  opacity: saving ? 1 : 0,
                  duration: const Duration(milliseconds: 150),
                  child: const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: _spinnerColor),
                  ),
                ),
              ),
            ),
          ],
        ),
        const Divider(height: 1),
        ConstrainedBox(
          constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.3),
          child: ListView(
            shrinkWrap: true,
            padding: EdgeInsets.zero,
            children: [
              for (final ruleId in ruleIds)
                CheckboxListTile(
                  dense: true,
                  visualDensity: VisualDensity.compact,
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  checkboxShape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(4)),
                  title: Text(rules[ruleId]!),
                  value: _chosen.contains(ruleId),
                  onChanged: (chosen) {
                    final ruleIds = Set<String>.of(_chosen);
                    chosen == true ? ruleIds.add(ruleId) : ruleIds.remove(ruleId);
                    _setChosen(ruleIds);
                  },
                ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 18),
          child: Text(_rulesError ?? '',
              style: TextStyle(color: theme.colorScheme.error, fontSize: 13)),
        ),
      ],
    );
  }

  Widget _buildError(ThemeData theme) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildIcon(theme, Icons.error_outline),
        const SizedBox(height: 12),
        Text(
          _error!,
          textAlign: TextAlign.center,
          style: TextStyle(color: theme.colorScheme.error),
        ),
        const SizedBox(height: 20),
        _buildButton('Try again', _loadStatus),
      ],
    );
  }

  Widget _buildIcon(ThemeData theme, IconData icon) {
    return CircleAvatar(
      radius: 26,
      backgroundColor: theme.colorScheme.surfaceContainerHighest,
      child: Icon(icon, size: 26, color: theme.colorScheme.primary),
    );
  }

  Widget _buildButton(String label, VoidCallback onPressed) {
    return SizedBox(
      width: double.infinity,
      child: FilledButton.tonal(
        onPressed: onPressed,
        style: FilledButton.styleFrom(
          minimumSize: const Size.fromHeight(44),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
        child: Text(label),
      ),
    );
  }
}

/// Soft bars shaped like the sheet, fading in and out while it loads
class _LoadingPlaceholder extends StatefulWidget {
  const _LoadingPlaceholder();

  @override
  State<_LoadingPlaceholder> createState() => _LoadingPlaceholderState();
}

class _LoadingPlaceholderState extends State<_LoadingPlaceholder>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  Widget _bar(double? width, double height, double radius) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: _spinnerColor.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(radius),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween<double>(begin: 0.4, end: 1).animate(
          CurvedAnimation(parent: _pulse, curve: Curves.easeInOut)),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _bar(170, 16, 8),
          const SizedBox(height: 8),
          _bar(110, 12, 6),
          const SizedBox(height: 16),
          _bar(double.infinity, 44, 12),
        ],
      ),
    );
  }
}
