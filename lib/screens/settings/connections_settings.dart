import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../data/model_connection.dart';
import '../../services/connection_service.dart';
import '../../services/node_discovery_service.dart';
import '../../state/app_state.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_text.dart';
import '../../widgets/adaptive_row.dart';
import '../../widgets/ere_controls.dart';
import '../../widgets/settings_kit.dart';

IconData connectionProviderIcon(ConnectionProvider provider) =>
    switch (provider) {
      ConnectionProvider.erebrus => Symbols.hub,
      ConnectionProvider.llamaCpp => Symbols.memory,
      ConnectionProvider.ollama => Symbols.deployed_code,
      ConnectionProvider.lmStudio => Symbols.desktop_windows,
      ConnectionProvider.vllm => Symbols.bolt,
      ConnectionProvider.openAi => Symbols.auto_awesome,
      ConnectionProvider.anthropic => Symbols.emergency,
      ConnectionProvider.openRouter => Symbols.alt_route,
      ConnectionProvider.custom => Symbols.link,
    };

Color remoteStateColor(RemoteModelState state) => switch (state) {
  RemoteModelState.loaded => AppColors.success,
  RemoteModelState.loading => AppColors.warn,
  RemoteModelState.unloaded => AppColors.textMuted,
  RemoteModelState.available => AppColors.accentHi,
  RemoteModelState.failed => AppColors.danger,
  RemoteModelState.unknown => AppColors.textFaint,
};

/// Settings → Connections. Switches between the connection list and the
/// add/edit form in place, with a breadcrumb back to the list.
class ConnectionsSettingsPage extends StatefulWidget {
  const ConnectionsSettingsPage({
    super.key,
    required this.padding,
    this.onExit,
  });

  final EdgeInsets padding;
  final VoidCallback? onExit;

  @override
  State<ConnectionsSettingsPage> createState() =>
      _ConnectionsSettingsPageState();
}

class _ConnectionsSettingsPageState extends State<ConnectionsSettingsPage> {
  bool _editing = false;
  ModelConnection? _target;
  _ConnectionDraft? _prefill;

  void _openEditor({ModelConnection? connection, _ConnectionDraft? prefill}) =>
      setState(() {
        _editing = true;
        _target = connection;
        _prefill = prefill;
      });

  void _closeEditor() => setState(() {
    _editing = false;
    _target = null;
    _prefill = null;
  });

  @override
  Widget build(BuildContext context) {
    if (_editing) {
      return ListView(
        padding: widget.padding,
        children: [
          SettingsPageHeader(
            title: 'Connections',
            breadcrumb: [
              'Connections',
              _target == null ? 'New' : _target!.name,
            ],
            onBack: _closeEditor,
          ),
          _ConnectionEditor(
            key: ValueKey(_target?.id ?? 'new'),
            connection: _target,
            prefill: _prefill,
            onDone: _closeEditor,
          ),
        ],
      );
    }
    return AnimatedBuilder(
      animation: Listenable.merge([
        ConnectionService.instance,
        NodeDiscoveryService.instance,
      ]),
      builder: (context, _) {
        final service = ConnectionService.instance;
        final connections = service.connections;
        final knownHosts = connections
            .map((connection) => connection.hostLabel)
            .toSet();
        final discovered = NodeDiscoveryService.instance.nodes
            .where((node) => !knownHosts.contains('${node.host}:${node.port}'))
            .toList();
        return ListView(
          padding: widget.padding,
          children: [
            SettingsPageHeader(
              title: 'Connections',
              subtitle:
                  'Use models served by llama.cpp, Ollama, LM Studio, vLLM, other Erebrus nodes, or cloud providers. They appear in Chat’s model picker.',
              onBack: widget.onExit,
              trailing: Wrap(
                spacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (connections.isNotEmpty)
                    SettingsIconButton(
                      icon: Symbols.refresh,
                      tooltip: 'Refresh all',
                      onTap: service.refreshAll,
                    ),
                  PillButton(
                    'Add',
                    icon: Symbols.add,
                    tone: PillTone.primary,
                    onTap: () => _openEditor(),
                  ),
                ],
              ),
            ),
            if (connections.isEmpty)
              _EmptyConnections(
                onAdd: (provider) =>
                    _openEditor(prefill: _ConnectionDraft(provider: provider)),
              ),
            for (final connection in connections) ...[
              ConnectionModelsCard(
                connection: connection,
                onEdit: () => _openEditor(connection: connection),
              ),
              const SizedBox(height: 14),
            ],
            if (discovered.isNotEmpty) ...[
              const SizedBox(height: 12),
              SettingsGroup(
                title: 'Discovered on your network',
                description:
                    'Erebrus AI nodes advertising over mDNS. Add one to pin it, manage its loaded model, or reach it by address later.',
                children: [
                  for (final node in discovered)
                    SettingItem(
                      title: node.name,
                      description:
                          '${node.host}:${node.port} · ${node.models.length} model${node.models.length == 1 ? '' : 's'}',
                      control: PillButton(
                        'Add',
                        icon: Symbols.add_link,
                        onTap: () => _openEditor(
                          prefill: _ConnectionDraft(
                            provider: ConnectionProvider.erebrus,
                            name: node.name,
                            baseUrl: 'http://${node.host}:${node.port}/v1',
                            apiKey: node.accessToken,
                            modelIds: node.models.map((m) => m.id).toList(),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ],
        );
      },
    );
  }
}

class _EmptyConnections extends StatelessWidget {
  const _EmptyConnections({required this.onAdd});

  final ValueChanged<ConnectionProvider> onAdd;

  @override
  Widget build(BuildContext context) {
    const quick = [
      ConnectionProvider.llamaCpp,
      ConnectionProvider.ollama,
      ConnectionProvider.lmStudio,
      ConnectionProvider.erebrus,
      ConnectionProvider.openAi,
      ConnectionProvider.anthropic,
    ];
    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.stroke),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: AppColors.accent.withA(0.12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(Symbols.cloud, color: AppColors.accentHi),
          ),
          const SizedBox(height: 14),
          Text(
            'No connections yet',
            style: AppText.grotesk(16, weight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          Text(
            'Connect a model server running on this computer, another machine on your network, or a cloud API. You can list its models, pick which ones to use, and load or offload them from here.',
            style: AppText.grotesk(
              13,
              color: AppColors.textSecondary,
              height: 1.45,
            ),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final provider in quick)
                PillButton(
                  provider.label,
                  icon: connectionProviderIcon(provider),
                  compact: true,
                  onTap: () => onAdd(provider),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// A connection with its selected models, live memory state, and
/// load/offload/use actions. Shared by Settings and Models → Network.
class ConnectionModelsCard extends StatelessWidget {
  const ConnectionModelsCard({
    super.key,
    required this.connection,
    this.onEdit,
    this.onUse,
  });

  final ModelConnection connection;
  final VoidCallback? onEdit;

  /// Called after a model is selected for chat (e.g. switch to Chat tab).
  final VoidCallback? onUse;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: ConnectionService.instance,
      builder: (context, _) {
        final service = ConnectionService.instance;
        final app = AppScope.of(context);
        final error = service.errorFor(connection.id);
        final refreshing = service.isRefreshing(connection.id);
        final models = service.modelsFor(connection);
        final loadedCount = models
            .where((model) => model.state == RemoteModelState.loaded)
            .length;
        final status = !connection.enabled
            ? 'DISABLED'
            : refreshing
            ? 'CHECKING'
            : error != null
            ? 'UNREACHABLE'
            : 'ONLINE';
        final statusColor = !connection.enabled
            ? AppColors.textMuted
            : refreshing
            ? AppColors.warn
            : error != null
            ? AppColors.danger
            : AppColors.success;
        return Container(
          decoration: BoxDecoration(
            color: AppColors.surface,
            border: Border.all(color: AppColors.stroke),
            borderRadius: BorderRadius.circular(16),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 13, 10, 13),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    // Narrow cards move the status pill under the name so
                    // the name keeps its full width.
                    final narrow = constraints.maxWidth < 420;
                    final pill = StatePill(
                      status,
                      color: statusColor,
                      pulse: refreshing,
                    );
                    return Row(
                      children: [
                        Container(
                          width: 38,
                          height: 38,
                          decoration: BoxDecoration(
                            color: AppColors.surface3,
                            borderRadius: BorderRadius.circular(11),
                          ),
                          child: Icon(
                            connectionProviderIcon(connection.provider),
                            size: 19,
                            color: AppColors.textSecondary,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                connection.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: AppText.grotesk(
                                  14.5,
                                  weight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                [
                                  connection.provider.label,
                                  connection.hostLabel,
                                  if (connection
                                          .provider
                                          .supportsModelControl &&
                                      error == null)
                                    '$loadedCount loaded',
                                ].join(' · '),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: AppText.mono(
                                  10.5,
                                  color: AppColors.textMuted,
                                ),
                              ),
                              if (narrow) ...[const SizedBox(height: 6), pill],
                            ],
                          ),
                        ),
                        if (!narrow) ...[const SizedBox(width: 8), pill],
                        const SizedBox(width: 4),
                        _ConnectionMenu(connection: connection, onEdit: onEdit),
                      ],
                    );
                  },
                ),
              ),
              if (error != null && connection.enabled)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: SettingsNote(
                    error,
                    tone: NoteTone.danger,
                    icon: Symbols.error,
                  ),
                ),
              if (models.isEmpty)
                Container(
                  decoration: const BoxDecoration(
                    border: Border(
                      top: BorderSide(color: AppColors.strokeSoft),
                    ),
                  ),
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          'No models selected for this connection.',
                          style: AppText.grotesk(
                            12.5,
                            color: AppColors.textMuted,
                          ),
                        ),
                      ),
                      if (onEdit != null)
                        PillButton(
                          'Choose models',
                          compact: true,
                          onTap: onEdit,
                        ),
                    ],
                  ),
                ),
              for (final model in models)
                _RemoteModelRow(
                  connection: connection,
                  model: model,
                  selected:
                      app.selectedNetworkNodeId == connection.nodeId &&
                      app.selectedModelId == model.id,
                  busy: service.isModelBusy(connection.id, model.id),
                  reachable: error == null && !refreshing,
                  onUse: () {
                    app.selectConnectionModel(connection, model.id);
                    if (onUse != null) {
                      onUse!();
                    } else {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            'Chat will use ${model.id} on ${connection.name}',
                          ),
                        ),
                      );
                    }
                  },
                ),
            ],
          ),
        );
      },
    );
  }
}

class _ConnectionMenu extends StatelessWidget {
  const _ConnectionMenu({required this.connection, this.onEdit});

  final ModelConnection connection;
  final VoidCallback? onEdit;

  @override
  Widget build(BuildContext context) {
    final service = ConnectionService.instance;
    return MenuAnchor(
      style: const MenuStyle(
        backgroundColor: WidgetStatePropertyAll(AppColors.surface2),
        surfaceTintColor: WidgetStatePropertyAll(Colors.transparent),
      ),
      menuChildren: [
        if (onEdit != null)
          MenuItemButton(
            leadingIcon: const Icon(Symbols.edit, size: 17),
            onPressed: onEdit,
            child: const Text('Edit connection'),
          ),
        MenuItemButton(
          leadingIcon: const Icon(Symbols.refresh, size: 17),
          onPressed: connection.enabled
              ? () => service.refresh(connection)
              : null,
          child: const Text('Refresh status'),
        ),
        MenuItemButton(
          leadingIcon: Icon(
            connection.enabled ? Symbols.pause_circle : Symbols.play_circle,
            size: 17,
          ),
          onPressed: () =>
              service.setEnabled(connection.id, !connection.enabled),
          child: Text(connection.enabled ? 'Disable' : 'Enable'),
        ),
        MenuItemButton(
          leadingIcon: const Icon(
            Symbols.delete,
            size: 17,
            color: AppColors.danger,
          ),
          onPressed: () => _confirmRemove(context),
          child: Text(
            'Remove',
            style: AppText.grotesk(14, color: AppColors.danger),
          ),
        ),
      ],
      builder: (context, controller, _) => SettingsIconButton(
        icon: Symbols.more_vert,
        tooltip: 'Connection options',
        onTap: () => controller.isOpen ? controller.close() : controller.open(),
      ),
    );
  }

  Future<void> _confirmRemove(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remove ${connection.name}?'),
        content: const Text(
          'Its saved API key is deleted from this device. Models on the server are not affected.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('CANCEL'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('REMOVE'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await ConnectionService.instance.remove(connection.id);
    }
  }
}

class _RemoteModelRow extends StatelessWidget {
  const _RemoteModelRow({
    required this.connection,
    required this.model,
    required this.selected,
    required this.busy,
    required this.reachable,
    required this.onUse,
  });

  final ModelConnection connection;
  final RemoteModelInfo model;
  final bool selected;
  final bool busy;

  /// False while the server is unreachable or being re-checked, when the
  /// last known model state can't be trusted.
  final bool reachable;
  final VoidCallback onUse;

  @override
  Widget build(BuildContext context) {
    final control = ConnectionService.instance.supportsModelControl(connection);
    final state = reachable || busy ? model.state : RemoteModelState.unknown;
    final loaded = state == RemoteModelState.loaded;
    final loading = state == RemoteModelState.loading || busy;
    return Container(
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: AppColors.strokeSoft)),
      ),
      padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final narrow = constraints.maxWidth < 440;
          final info = Row(
            children: [
              LetterTile(
                model.id.isEmpty ? '?' : model.id[0].toUpperCase(),
                accent: selected,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      model.id,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.grotesk(13.5, weight: FontWeight.w600),
                    ),
                    if (model.detail.isNotEmpty || model.sizeBytes != null)
                      Text(
                        [
                          if (model.detail.isNotEmpty) model.detail,
                          if (model.sizeBytes != null)
                            _formatSize(model.sizeBytes!),
                        ].join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.mono(10.5, color: AppColors.textMuted),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              StatePill(
                loading && !loaded
                    ? RemoteModelState.loading.label
                    : state.label,
                color: remoteStateColor(
                  loading && !loaded ? RemoteModelState.loading : state,
                ),
                pulse: loading,
              ),
            ],
          );
          final actions = Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              if (control && connection.enabled)
                PillButton(
                  loaded ? 'Offload' : 'Load',
                  icon: loaded ? Symbols.eject : Symbols.memory,
                  compact: true,
                  busy: busy,
                  onTap: reachable ? () => _toggleLoad(context, loaded) : null,
                ),
              PillButton(
                selected ? 'In use' : 'Use',
                icon: selected ? Symbols.check : Symbols.chat,
                compact: true,
                tone: selected ? PillTone.subtle : PillTone.neutral,
                onTap: connection.enabled && !selected ? onUse : null,
              ),
            ],
          );
          if (narrow) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                info,
                const SizedBox(height: 8),
                Align(alignment: Alignment.centerRight, child: actions),
              ],
            );
          }
          return Row(
            children: [
              Expanded(child: info),
              const SizedBox(width: 10),
              actions,
            ],
          );
        },
      ),
    );
  }

  Future<void> _toggleLoad(BuildContext context, bool loaded) async {
    final service = ConnectionService.instance;
    try {
      if (loaded) {
        await service.unloadModel(connection, model.id);
      } else {
        await service.loadModel(connection, model.id);
      }
    } on Object catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '${loaded ? 'Offload' : 'Load'} failed: ${error is ConnectionException ? error.message : error}',
          ),
        ),
      );
    }
  }
}

String _formatSize(int bytes) {
  const gb = 1024 * 1024 * 1024;
  if (bytes >= gb) return '${(bytes / gb).toStringAsFixed(1)} GB';
  return '${(bytes / (1024 * 1024)).round()} MB';
}

// ─── Editor ──────────────────────────────────────────────────────────────────

class _ConnectionDraft {
  const _ConnectionDraft({
    required this.provider,
    this.name,
    this.baseUrl,
    this.apiKey,
    this.modelIds = const [],
  });

  final ConnectionProvider provider;
  final String? name;
  final String? baseUrl;
  final String? apiKey;
  final List<String> modelIds;
}

class _ConnectionEditor extends StatefulWidget {
  const _ConnectionEditor({
    super.key,
    this.connection,
    this.prefill,
    required this.onDone,
  });

  final ModelConnection? connection;
  final _ConnectionDraft? prefill;
  final VoidCallback onDone;

  @override
  State<_ConnectionEditor> createState() => _ConnectionEditorState();
}

class _ConnectionEditorState extends State<_ConnectionEditor> {
  late ConnectionProvider _provider;
  final _name = TextEditingController();
  final _baseUrl = TextEditingController();
  final _apiKey = TextEditingController();
  final _maxTokens = TextEditingController();
  final _manualIds = TextEditingController();
  final _filter = TextEditingController();
  bool _showKey = false;
  bool _loadingModels = false;
  bool _saving = false;
  String? _modelsError;
  String? _formError;
  List<RemoteModelInfo>? _available;
  final Set<String> _selected = {};

  bool get _editing => widget.connection != null;
  bool get _hasSavedKey =>
      _editing && ConnectionService.instance.hasApiKey(widget.connection!.id);

  @override
  void initState() {
    super.initState();
    final existing = widget.connection;
    final prefill = widget.prefill;
    _provider =
        existing?.provider ?? prefill?.provider ?? ConnectionProvider.llamaCpp;
    _name.text = existing?.name ?? prefill?.name ?? _provider.label;
    _baseUrl.text =
        existing?.baseUrl ?? prefill?.baseUrl ?? _provider.defaultBaseUrl;
    _apiKey.text = prefill?.apiKey ?? '';
    _maxTokens.text = existing?.maxTokensLimit?.toString() ?? '';
    _selected.addAll(existing?.modelIds ?? prefill?.modelIds ?? const []);
    if (_selected.isNotEmpty || existing != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _loadModels());
    }
  }

  @override
  void dispose() {
    for (final controller in [
      _name,
      _baseUrl,
      _apiKey,
      _maxTokens,
      _manualIds,
      _filter,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  void _setProvider(ConnectionProvider next) {
    setState(() {
      if (_name.text.trim().isEmpty || _name.text == _provider.label) {
        _name.text = next.label;
      }
      if (_baseUrl.text.trim().isEmpty ||
          _baseUrl.text == _provider.defaultBaseUrl) {
        _baseUrl.text = next.defaultBaseUrl;
      }
      _provider = next;
      _available = null;
      _modelsError = null;
    });
  }

  /// The key to authenticate model listing: typed value, else the saved one.
  String get _effectiveKey {
    final typed = _apiKey.text.trim();
    if (typed.isNotEmpty || !_editing) return typed;
    final target = ConnectionService.instance.targetFor(
      widget.connection!.nodeId,
      widget.connection!.modelIds.firstOrNull ?? '',
    );
    return target?.accessToken ?? '';
  }

  Future<void> _loadModels() async {
    setState(() {
      _loadingModels = true;
      _modelsError = null;
    });
    try {
      final models = await ConnectionService.instance.fetchAvailableModels(
        provider: _provider,
        baseUrl: _baseUrl.text,
        apiKey: _effectiveKey,
      );
      if (!mounted) return;
      setState(() {
        _available = models;
        if (models.isEmpty) {
          _modelsError = 'The server is reachable but reports no models.';
        }
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _modelsError = error is ConnectionException
            ? error.message
            : 'Could not reach the server: $error';
      });
    } finally {
      if (mounted) setState(() => _loadingModels = false);
    }
  }

  List<String> get _finalModelIds => [
    ..._selected,
    ...ConnectionService.parseModelIds(_manualIds.text),
  ];

  Future<void> _save() async {
    final url = _baseUrl.text.trim();
    final uri = Uri.tryParse(ConnectionService.normalizeBaseUrl(url));
    if (url.isEmpty || uri == null || uri.host.isEmpty) {
      setState(
        () => _formError =
            'Enter a valid base URL, e.g. http://localhost:8080/v1',
      );
      return;
    }
    final maxTokensText = _maxTokens.text.trim();
    final maxTokens = maxTokensText.isEmpty
        ? null
        : int.tryParse(maxTokensText);
    if (maxTokensText.isNotEmpty && (maxTokens == null || maxTokens < 1)) {
      setState(() => _formError = 'Max Tokens limit must be a positive number');
      return;
    }
    if (_provider.requiresApiKey &&
        _apiKey.text.trim().isEmpty &&
        !_hasSavedKey) {
      setState(() => _formError = '${_provider.label} requires an API key');
      return;
    }
    if (_finalModelIds.isEmpty) {
      setState(
        () => _formError =
            'Select at least one model, or enter model IDs manually',
      );
      return;
    }
    setState(() {
      _saving = true;
      _formError = null;
    });
    try {
      await ConnectionService.instance.save(
        id: widget.connection?.id,
        provider: _provider,
        name: _name.text,
        baseUrl: url,
        maxTokensLimit: maxTokens,
        modelIds: _finalModelIds,
        // Blank while editing keeps the saved key.
        apiKey: _apiKey.text.trim().isEmpty && _editing
            ? null
            : _apiKey.text.trim(),
      );
      if (mounted) widget.onDone();
    } on Object catch (error) {
      if (mounted) setState(() => _formError = 'Could not save: $error');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _clear() {
    setState(() {
      _provider = ConnectionProvider.llamaCpp;
      _name.text = _provider.label;
      _baseUrl.text = _provider.defaultBaseUrl;
      _apiKey.clear();
      _maxTokens.clear();
      _manualIds.clear();
      _selected.clear();
      _available = null;
      _modelsError = null;
      _formError = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final maxTokensSet = _maxTokens.text.trim().isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsFormCard(
          children: [
            SettingsFormRow(
              title: 'Connection',
              description: 'OpenAI, Anthropic, or a compatible local endpoint.',
              field: EreSelect<ConnectionProvider>(
                value: _provider,
                width: double.infinity,
                leading: Icon(
                  connectionProviderIcon(_provider),
                  size: 17,
                  color: AppColors.accentHi,
                ),
                onChanged: _setProvider,
                options: [
                  for (final provider in ConnectionProvider.values)
                    SelectOption(
                      provider,
                      provider.label,
                      icon: connectionProviderIcon(provider),
                      description: provider.supportsModelControl
                          ? 'Remote load & offload supported'
                          : provider.requiresApiKey
                          ? 'Cloud API · API key required'
                          : 'OpenAI-compatible',
                    ),
                ],
              ),
            ),
            SettingsFormRow(
              title: 'Connection name',
              field: EreTextField(controller: _name, hint: _provider.label),
            ),
            SettingsFormRow(
              title: 'Base URL',
              description: 'OpenAI-compatible endpoint.',
              field: EreTextField(
                controller: _baseUrl,
                hint: _provider.defaultBaseUrl,
                mono: true,
                keyboardType: TextInputType.url,
              ),
            ),
            SettingsFormRow(
              title: 'API key',
              description: _provider.requiresApiKey
                  ? 'Required. Stored in the system keychain on this device.'
                  : _provider.apiKeyHint ??
                        'Optional. Only if the server was started with a key.',
              field: EreTextField(
                controller: _apiKey,
                obscure: !_showKey,
                mono: true,
                hint: _hasSavedKey
                    ? 'Saved · leave blank to keep'
                    : _provider.requiresApiKey
                    ? 'sk-…'
                    : 'Optional',
                suffix: IconButton(
                  tooltip: _showKey ? 'Hide key' : 'Show key',
                  icon: Icon(
                    _showKey ? Symbols.visibility_off : Symbols.visibility,
                    size: 18,
                    color: AppColors.textMuted,
                  ),
                  onPressed: () => setState(() => _showKey = !_showKey),
                ),
              ),
            ),
            SettingsFormRow(
              title: 'Max Tokens limit',
              description:
                  'Caps Max Tokens for this connection. Leave blank to use each persona’s response length.',
              field: EreTextField(
                controller: _maxTokens,
                hint: '32768',
                mono: true,
                keyboardType: TextInputType.number,
                onChanged: (_) => setState(() {}),
              ),
              fieldNote: maxTokensSet
                  ? const SettingsNote(
                      'If the upstream provider does not support this value, requests may fail.',
                      tone: NoteTone.warn,
                    )
                  : null,
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 14, 18, 16),
              child: SettingsNote(
                _provider.isLocal
                    ? 'Prompts and recent chat history are sent to this server when you chat with its models. Nothing leaves your network unless the server does.'
                    : 'Prompts and recent chat history are sent to ${_provider.label}, a third-party cloud service, when you chat with its models. Usage is billed to your API key.',
                icon: Symbols.info,
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        _modelsCard(),
        if (_formError != null) ...[
          const SizedBox(height: 12),
          SettingsNote(_formError!, tone: NoteTone.danger, icon: Symbols.error),
        ],
        const SizedBox(height: 16),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            if (!_editing)
              PillButton('Clear', onTap: _saving ? null : _clear)
            else
              PillButton('Cancel', onTap: _saving ? null : widget.onDone),
            const SizedBox(width: 10),
            PillButton(
              _editing ? 'Save changes' : 'Add connection',
              tone: PillTone.primary,
              busy: _saving,
              onTap: _save,
            ),
          ],
        ),
      ],
    );
  }

  Widget _modelsCard() {
    final available = _available;
    final query = _filter.text.trim().toLowerCase();
    final filtered = available
        ?.where(
          (model) => query.isEmpty || model.id.toLowerCase().contains(query),
        )
        .toList();
    final selectedCount = _finalModelIds.toSet().length;
    return SettingsFormCard(
      header: Padding(
        padding: const EdgeInsets.fromLTRB(18, 14, 14, 14),
        child: AdaptiveRow(
          leading: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Models',
                style: AppText.grotesk(14.5, weight: FontWeight.w500),
              ),
              const SizedBox(height: 2),
              Text(
                '$selectedCount model${selectedCount == 1 ? '' : 's'} selected',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.grotesk(12, color: AppColors.textMuted),
              ),
            ],
          ),
          trailing: PillButton(
            available == null ? 'Load available models' : 'Reload',
            icon: Symbols.sync,
            busy: _loadingModels,
            onTap: _loadModels,
          ),
          minLeadingWidth: 120,
          stackedAlignment: AlignmentDirectional.centerEnd,
        ),
      ),
      children: [
        if (_modelsError != null)
          Padding(
            padding: const EdgeInsets.all(16),
            child: SettingsNote(
              _modelsError!,
              tone: NoteTone.danger,
              icon: Symbols.error,
            ),
          ),
        if (filtered != null && available!.isNotEmpty)
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
                child: Row(
                  children: [
                    if (available.length > 8)
                      Expanded(
                        child: EreTextField(
                          controller: _filter,
                          hint: 'Filter ${available.length} models…',
                          onChanged: (_) => setState(() {}),
                        ),
                      )
                    else
                      const Spacer(),
                    const SizedBox(width: 8),
                    PillButton(
                      'Select all',
                      compact: true,
                      tone: PillTone.subtle,
                      onTap: () => setState(
                        () => _selected.addAll(filtered.map((m) => m.id)),
                      ),
                    ),
                    PillButton(
                      'None',
                      compact: true,
                      tone: PillTone.subtle,
                      onTap: () => setState(
                        () => _selected.removeAll(filtered.map((m) => m.id)),
                      ),
                    ),
                  ],
                ),
              ),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 320),
                child: ListView(
                  shrinkWrap: true,
                  padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                  children: [
                    for (final model in filtered)
                      _ModelCheckRow(
                        model: model,
                        checked: _selected.contains(model.id),
                        onChanged: (value) => setState(() {
                          if (value) {
                            _selected.add(model.id);
                          } else {
                            _selected.remove(model.id);
                          }
                        }),
                      ),
                  ],
                ),
              ),
            ],
          ),
        if (available == null && _selected.isNotEmpty && !_loadingModels)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final id in _selected)
                  InputChip(
                    label: Text(id, style: AppText.mono(11.5)),
                    backgroundColor: AppColors.surface2,
                    side: const BorderSide(color: AppColors.strokeHi),
                    onDeleted: () => setState(() => _selected.remove(id)),
                  ),
              ],
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Or enter model IDs manually (one per line or comma-separated)',
                style: AppText.grotesk(13.5, weight: FontWeight.w500),
              ),
              const SizedBox(height: 10),
              EreTextField(
                controller: _manualIds,
                hint: 'gpt-oss-20b\nqwen3-14b',
                mono: true,
                maxLines: 4,
                minLines: 3,
                onChanged: (_) => setState(() {}),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ModelCheckRow extends StatelessWidget {
  const _ModelCheckRow({
    required this.model,
    required this.checked,
    required this.onChanged,
  });

  final RemoteModelInfo model;
  final bool checked;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: () => onChanged(!checked),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
        child: Row(
          children: [
            Icon(
              checked ? Symbols.check_box : Symbols.check_box_outline_blank,
              fill: checked ? 1 : 0,
              size: 20,
              color: checked ? AppColors.accent : AppColors.textMuted,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    model.id,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.mono(12.5, color: AppColors.textPrimary),
                  ),
                  if (model.detail.isNotEmpty || model.sizeBytes != null)
                    Text(
                      [
                        if (model.detail.isNotEmpty) model.detail,
                        if (model.sizeBytes != null)
                          _formatSize(model.sizeBytes!),
                      ].join(' · '),
                      style: AppText.mono(10.5, color: AppColors.textMuted),
                    ),
                ],
              ),
            ),
            if (model.state != RemoteModelState.available &&
                model.state != RemoteModelState.unknown)
              StatePill(
                model.state.label,
                color: remoteStateColor(model.state),
              ),
          ],
        ),
      ),
    );
  }
}
