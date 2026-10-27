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
  bool _saving = false;
  String? _rulesError;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadStatus();
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
      _rules = _registered
          ? await NexusPush.instance.fetchNotifications(widget.database)
          : NexusRules(rules: {}, chosen: {});
    });
  }

  Future<void> _toggle() {
    return _run(() async {
      if (_registered) {
        await NexusPush.instance.unregister(widget.database);
        _rules = NexusRules(rules: {}, chosen: {});
      } else {
        await NexusPush.instance.register(widget.database);
        _rules = await NexusPush.instance.fetchNotifications(widget.database);
      }
      _registered = !_registered;
    });
  }

  Future<void> _toggleRule(String ruleId, bool chosen) async {
    final ruleIds = Set<String>.of(_rules.chosen);
    chosen ? ruleIds.add(ruleId) : ruleIds.remove(ruleId);

    setState(() {
      _saving = true;
      _rulesError = null;
    });

    try {
      await NexusPush.instance.selectNotifications(widget.database, ruleIds);
      _rules = NexusRules(rules: _rules.rules, chosen: ruleIds);
    } on NexusPushException catch (e) {
      _rulesError = e.message;
    } catch (e) {
      debugPrint('Could not save the notifications: $e');
      _rulesError = 'Could not save your choice. Please try again.';
    }

    if (mounted) {
      setState(() {
        _saving = false;
      });
    }
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
      height: height < 64 ? 64 : height,
      child: const Center(
        child: CircularProgressIndicator(color: _spinnerColor),
      ),
    );
  }

  Widget _buildStatus(ThemeData theme) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildIcon(
            theme,
            _registered
                ? Icons.notifications_active_outlined
                : Icons.notifications_off_outlined),
        const SizedBox(height: 12),
        Text(
          _registered ? 'Notifications are on' : 'Notifications are off',
          style:
              theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 2),
        Text('for ${widget.database}', style: theme.textTheme.bodyMedium),
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Text(
            'Only notifications that are set up for IMS TARP will be available.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
        if (_registered) ...[
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
        'No notifications are available for ${widget.database}. Note Nexus Mobile can only receive IMS TARP notifications.',
        textAlign: TextAlign.center,
        style: theme.textTheme.bodyMedium,
      );
    }

    final ruleIds = rules.keys.toList()
      ..sort((a, b) => rules[a]!.toLowerCase().compareTo(rules[b]!.toLowerCase()));

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Choose what you receive',
            style: theme.textTheme.labelLarge
                ?.copyWith(fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
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
                  value: _rules.chosen.contains(ruleId),
                  onChanged: _saving
                      ? null
                      : (chosen) => _toggleRule(ruleId, chosen ?? false),
                ),
            ],
          ),
        ),
        if (_rulesError != null) ...[
          const SizedBox(height: 8),
          Text(_rulesError!,
              style: TextStyle(color: theme.colorScheme.error, fontSize: 13)),
        ],
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
