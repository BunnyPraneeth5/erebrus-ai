import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../data/catalog_service.dart';
import '../../data/imported_model.dart';
import '../../data/mock_data.dart';
import '../../data/model_catalog.dart';
import '../../services/backend_probe_service.dart';
import '../../services/device_info_service.dart';
import '../../services/inference_memory_policy.dart';
import '../../services/inference_planner.dart';
import '../../services/inference_readiness_service.dart';
import '../../services/inference_service.dart';
import '../../services/imported_model_service.dart';
import '../../services/local_server_service.dart';
import '../../services/model_download_service.dart';
import '../../services/model_package_service.dart';
import '../../services/connection_service.dart';
import '../../services/node_discovery_service.dart';
import '../../services/storage_service.dart';
import '../../org/shared_model.dart';
import '../../state/app_state.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_text.dart';
import '../../widgets/adaptive_row.dart';
import '../../widgets/ere_controls.dart';
import '../auth/sign_in.dart';
import '../settings/connections_settings.dart';
import '../settings/settings_screen.dart';

class ModelsScreen extends StatefulWidget {
  const ModelsScreen({
    super.key,
    required this.wide,
    this.initialSubTab = 0,
    this.onOpenChat,
  });

  final bool wide;
  final int initialSubTab;
  final VoidCallback? onOpenChat;

  @override
  State<ModelsScreen> createState() => _ModelsScreenState();
}

class _ModelsScreenState extends State<ModelsScreen> {
  late int _tab; // 0 = LOCAL, 1 = NETWORK

  @override
  void initState() {
    super.initState();
    _tab = widget.initialSubTab;
  }

  final _searchController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _setQuery(String q) => setState(() => _query = q);

  void _rescan() {
    unawaited(
      NodeDiscoveryService.instance.stop().then((_) {
        if (mounted) NodeDiscoveryService.instance.start();
      }),
    );
  }

  int get _networkCount =>
      NodeDiscoveryService.instance.nodes.length +
      ConnectionService.instance.enabledConnections.length;

  String get _browsingLabel => NodeDiscoveryService.instance.lastError != null
      ? 'DISCOVERY NEEDS ATTENTION · TAP RESCAN'
      : 'BROWSING _EREBRUSAI._TCP · ${NodeDiscoveryService.instance.nodes.length} NODES FOUND';

  List<String> get _segmentItems => [
    'LOCAL · ${{...ModelDownloadService.instance.completed, ...ModelPackageService.instance.installed.where((record) => record.runnable).map((record) => record.modelId), ...ImportedModelService.instance.models.map((record) => record.id)}.length}',
    'NETWORK · $_networkCount',
  ];

  int get _downloadedBytes =>
      ModelDownloadService.instance.downloadedBytes +
      ModelPackageService.instance.downloadedBytes +
      ImportedModelService.instance.storedBytes;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([
        NodeDiscoveryService.instance,
        ConnectionService.instance,
        ModelDownloadService.instance,
        ModelPackageService.instance,
        ImportedModelService.instance,
        LocalServerService.instance,
      ]),
      builder: (context, _) {
        return widget.wide ? _buildWide(context) : _buildNarrow(context);
      },
    );
  }

  // ─── Desktop ───────────────────────────────────────────────────────────────

  Widget _listStack(bool wide) => Expanded(
    child: IndexedStack(
      index: _tab,
      children: [
        _LocalList(wide: true, query: _query),
        _NetworkList(wide: true, query: _query, onOpenChat: widget.onOpenChat),
      ],
    ),
  );

  Widget _buildWide(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 24, 32, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Models', style: AppText.screenTitle()),
                    const SizedBox(height: 3),
                    Text(
                      'Local downloads and models discovered on your network.',
                      style: AppText.grotesk(
                        13,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              if (_tab == 0) ...[
                GhostButton(
                  'IMPORT',
                  icon: Symbols.upload_file,
                  onTap: () => _showImportOptions(context),
                ),
                const SizedBox(width: 10),
              ],
              _SearchField(controller: _searchController, onChanged: _setQuery),
            ],
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              SizedBox(
                width: 300,
                child: EreSegmented(
                  items: _segmentItems,
                  index: _tab,
                  onChanged: (i) => setState(() => _tab = i),
                ),
              ),
              const SizedBox(width: 14),
              if (_tab == 1) ...[
                const Icon(Symbols.wifi, size: 15, color: AppColors.success),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    _browsingLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.mono(
                      10.5,
                      color: AppColors.textMuted,
                      lsEm: 0.06,
                    ),
                  ),
                ),
              ] else
                Expanded(
                  child: Text(
                    'STORAGE · ${formatBytes(_downloadedBytes)} USED',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.mono(
                      10.5,
                      color: AppColors.textMuted,
                      lsEm: 0.06,
                    ),
                  ),
                ),
              const SizedBox(width: 14),
              if (_tab == 1)
                GhostButton('RESCAN', icon: Symbols.refresh, onTap: _rescan),
            ],
          ),
          if (_tab == 0) ...[
            const SizedBox(height: 10),
            const _ModelsFolderPath(),
          ],
          const SizedBox(height: 14),
          _listStack(true),
        ],
      ),
    );
  }

  // ─── Mobile ────────────────────────────────────────────────────────────────

  Widget _buildNarrow(BuildContext context) {
    return SafeArea(
      bottom: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Models', style: AppText.screenTitle()),
                const SizedBox(height: 12),
                _SearchField(
                  controller: _searchController,
                  onChanged: _setQuery,
                  width: double.infinity,
                ),
                const SizedBox(height: 12),
                EreSegmented(
                  items: _segmentItems,
                  index: _tab,
                  onChanged: (i) => setState(() => _tab = i),
                ),
                const SizedBox(height: 12),
                if (_tab == 0) ...[
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'STORAGE · ${formatBytes(_downloadedBytes)} USED',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppText.mono(
                            10,
                            color: AppColors.textMuted,
                            lsEm: 0.08,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      GhostButton(
                        'IMPORT',
                        icon: Symbols.upload_file,
                        onTap: () => _showImportOptions(context),
                      ),
                    ],
                  ),
                  const SizedBox(height: 9),
                  const _ModelsFolderPath(compact: true),
                ] else
                  Row(
                    children: [
                      const Icon(
                        Symbols.wifi,
                        size: 15,
                        color: AppColors.success,
                      ),
                      const SizedBox(width: 7),
                      Expanded(
                        child: Text(
                          _browsingLabel,
                          style: AppText.mono(
                            10,
                            color: AppColors.textMuted,
                            lsEm: 0.06,
                          ),
                        ),
                      ),
                      GestureDetector(
                        onTap: _rescan,
                        child: Text(
                          'RESCAN',
                          style: AppText.mono(
                            10,
                            weight: FontWeight.w600,
                            color: AppColors.textSecondary,
                            lsEm: 0.05,
                          ),
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Expanded(
            child: IndexedStack(
              index: _tab,
              children: [
                _LocalList(wide: false, query: _query),
                _NetworkList(
                  wide: false,
                  query: _query,
                  onOpenChat: widget.onOpenChat,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _showImportOptions(BuildContext context) async {
    final format = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppColors.surface,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Import local model', style: AppText.screenTitle(size: 22)),
              const SizedBox(height: 8),
              Text(
                'Erebrus validates the package before registering it. Imported files never leave this device unless LAN sharing is enabled.',
                style: AppText.grotesk(
                  13,
                  color: AppColors.textSecondary,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 18),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(
                  Symbols.description,
                  color: AppColors.accent,
                ),
                title: const Text('GGUF model file'),
                subtitle: const Text(
                  'Portable llama.cpp model · macOS, iOS, Android and desktop',
                ),
                trailing: const Icon(Symbols.chevron_right),
                onTap: () => Navigator.pop(sheetContext, 'gguf'),
              ),
              if (Platform.isMacOS &&
                  DeviceInfoService.detect().platform == 'macos-arm64')
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(
                    Symbols.folder_special,
                    color: AppColors.accent,
                  ),
                  title: const Text('MLX model directory'),
                  subtitle: const Text(
                    'Apple-silicon package with config, tokenizer and SafeTensors',
                  ),
                  trailing: const Icon(Symbols.chevron_right),
                  onTap: () => Navigator.pop(sheetContext, 'mlx'),
                ),
            ],
          ),
        ),
      ),
    );
    if (format == null || !context.mounted) return;
    try {
      ImportedModelDraft draft;
      if (format == 'gguf') {
        final result = await FilePicker.pickFiles(
          dialogTitle: 'Choose a GGUF model',
          type: FileType.custom,
          allowedExtensions: const ['gguf'],
          allowMultiple: false,
          withData: false,
        );
        final path = result?.files.single.path;
        if (path == null || path.isEmpty) return;
        draft = await ImportedModelService.instance.inspectGguf(path);
      } else {
        final path = await FilePicker.getDirectoryPath(
          dialogTitle: 'Choose an MLX model directory',
        );
        if (path == null || path.isEmpty) return;
        draft = await ImportedModelService.instance.inspectMlxDirectory(path);
      }
      if (!context.mounted) return;
      final confirmation = await _confirmImport(context, draft);
      if (confirmation == null) return;
      if (!context.mounted) return;
      final service = ImportedModelService.instance;
      final operation = service.import(
        confirmation.draft,
        copyIntoApp: confirmation.copyIntoApp,
      );
      if (confirmation.copyIntoApp) {
        unawaited(
          showDialog<void>(
            context: context,
            barrierDismissible: false,
            builder: (_) => const _ImportProgressDialog(),
          ),
        );
      }
      ImportedModel imported;
      try {
        imported = await operation;
      } finally {
        if (confirmation.copyIntoApp && context.mounted) {
          Navigator.of(context, rootNavigator: true).pop();
        }
      }
      if (!context.mounted) return;
      final app = AppScope.of(context);
      app.selectModel(
        imported.name,
        imported.quantization.isEmpty
            ? imported.format.toUpperCase()
            : imported.quantization,
        id: imported.id,
        variantId: imported.variantId,
      );
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${imported.name} imported and selected')),
      );
    } on ImportedModelException catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            error.code == 'import_cancelled'
                ? 'Model import cancelled'
                : 'Import failed: ${error.message}',
          ),
        ),
      );
    } on Object catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Import failed: $error')));
    }
  }

  Future<_ImportConfirmation?> _confirmImport(
    BuildContext context,
    ImportedModelDraft draft,
  ) async {
    final name = TextEditingController(text: draft.name);
    final parameters = TextEditingController(
      text: draft.parameterB > 0
          ? draft.parameterB
                .toStringAsFixed(2)
                .replaceFirst(RegExp(r'\.?0+$'), '')
          : '',
    );
    final architecture = TextEditingController(text: draft.architecture);
    final quantization = TextEditingController(text: draft.quantization);
    var copyIntoApp = true;
    final result = await showDialog<_ImportConfirmation>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Confirm imported model'),
          content: SingleChildScrollView(
            child: SizedBox(
              width: 440,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: name,
                    decoration: const InputDecoration(labelText: 'Model name'),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: parameters,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: const InputDecoration(
                      labelText: 'Parameters (billions)',
                      hintText: 'For example, 4 or 0.5',
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: architecture,
                    decoration: const InputDecoration(
                      labelText: 'Architecture',
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: quantization,
                    decoration: const InputDecoration(
                      labelText: 'Quantization',
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '${draft.format.toUpperCase()} · ${formatBytes(draft.sizeBytes)}',
                    style: AppText.mono(10.5, color: AppColors.textMuted),
                  ),
                  if (Platform.isMacOS) ...[
                    const SizedBox(height: 8),
                    SwitchListTile.adaptive(
                      contentPadding: EdgeInsets.zero,
                      value: copyIntoApp,
                      onChanged: (value) =>
                          setDialogState(() => copyIntoApp = value),
                      title: const Text('Copy into Erebrus storage'),
                      subtitle: Text(
                        copyIntoApp
                            ? 'Safer if the original is moved or disconnected.'
                            : 'Keep the original in place using a persistent macOS bookmark.',
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('CANCEL'),
            ),
            FilledButton(
              onPressed: () {
                final parsed = parameters.text.trim().isEmpty
                    ? 0.0
                    : double.tryParse(parameters.text.trim());
                if (name.text.trim().isEmpty || parsed == null || parsed < 0) {
                  ScaffoldMessenger.of(dialogContext).showSnackBar(
                    const SnackBar(
                      content: Text(
                        'Enter a name and a valid parameter count.',
                      ),
                    ),
                  );
                  return;
                }
                Navigator.pop(
                  dialogContext,
                  _ImportConfirmation(
                    draft: draft.copyWith(
                      name: name.text.trim(),
                      parameterB: parsed,
                      architecture: architecture.text.trim(),
                      quantization: quantization.text.trim(),
                    ),
                    copyIntoApp: copyIntoApp,
                  ),
                );
              },
              child: const Text('IMPORT'),
            ),
          ],
        ),
      ),
    );
    name.dispose();
    parameters.dispose();
    architecture.dispose();
    quantization.dispose();
    return result;
  }
}

class _ModelsFolderPath extends StatelessWidget {
  const _ModelsFolderPath({this.compact = false});

  final bool compact;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final path =
        app.modelsDirectory ??
        StorageService.instance.modelsDirectoryDisplayLabel;
    return Tooltip(
      message: path,
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 10 : 12,
          vertical: compact ? 7 : 8,
        ),
        decoration: BoxDecoration(
          color: AppColors.surface2,
          border: Border.all(color: AppColors.strokeSoft),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            const Icon(
              Symbols.folder_open,
              size: 15,
              color: AppColors.textMuted,
            ),
            const SizedBox(width: 8),
            Text(
              'MODELS FOLDER',
              style: AppText.mono(
                9,
                weight: FontWeight.w600,
                color: AppColors.textFaint,
                lsEm: 0.08,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                path,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.mono(10, color: AppColors.textSecondary),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ImportConfirmation {
  const _ImportConfirmation({required this.draft, required this.copyIntoApp});
  final ImportedModelDraft draft;
  final bool copyIntoApp;
}

class _ImportProgressDialog extends StatelessWidget {
  const _ImportProgressDialog();

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: ImportedModelService.instance,
      builder: (context, _) {
        final service = ImportedModelService.instance;
        return AlertDialog(
          title: const Text('Copying model into Erebrus'),
          content: SizedBox(
            width: 380,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                LinearProgressIndicator(
                  value: service.copyTotalBytes > 0
                      ? service.importProgress
                      : null,
                ),
                const SizedBox(height: 10),
                Text(
                  '${formatBytes(service.copiedBytes)} / ${formatBytes(service.copyTotalBytes)}',
                  style: AppText.mono(10.5, color: AppColors.textMuted),
                ),
                const SizedBox(height: 6),
                Text(
                  'Keep Erebrus open until the copy completes.',
                  style: AppText.grotesk(12.5, color: AppColors.textSecondary),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: service.isImporting ? service.cancelImport : null,
              child: const Text('CANCEL IMPORT'),
            ),
          ],
        );
      },
    );
  }
}

class _SearchField extends StatelessWidget {
  const _SearchField({
    required this.controller,
    required this.onChanged,
    this.width = 220,
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final double width;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      padding: const EdgeInsets.symmetric(horizontal: 13),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.stroke),
        borderRadius: BorderRadius.circular(11),
      ),
      child: Row(
        children: [
          const Icon(Symbols.search, size: 17, color: AppColors.textMuted),
          const SizedBox(width: 9),
          Expanded(
            child: TextField(
              controller: controller,
              onChanged: onChanged,
              style: AppText.grotesk(13),
              cursorColor: AppColors.accent,
              decoration: InputDecoration(
                isDense: true,
                border: InputBorder.none,
                contentPadding: const EdgeInsets.symmetric(vertical: 10),
                hintText: 'Search models…',
                hintStyle: AppText.grotesk(13, color: AppColors.textMuted),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── LOCAL tab ───────────────────────────────────────────────────────────────

class _LocalList extends StatefulWidget {
  const _LocalList({required this.wide, required this.query});

  final bool wide;
  final String query;

  @override
  State<_LocalList> createState() => _LocalListState();
}

class _LocalListState extends State<_LocalList> {
  late Future<List<CatalogEntry>> _catalogFuture;
  final Map<String, ModelVariant> _preferredVariants = {};
  final Map<String, BackendKind> _preferredBackends = {};
  List<BackendCapabilities> _capabilities = const [];
  late DeviceProfile _device;
  String? _selectedEntryId;

  @override
  void initState() {
    super.initState();
    _catalogFuture = _initializeCatalog();
  }

  Future<List<CatalogEntry>> _initializeCatalog() async {
    _device = await DeviceInfoService.detectAsync();
    return _loadCatalog();
  }

  Future<List<CatalogEntry>> _loadCatalog() async {
    final entries = await CatalogService.fetch();
    final catalog = entries.isEmpty ? modelCatalog : entries;
    final capabilities = await BackendProbeService.instance.probe(
      device: _device,
    );
    _capabilities = capabilities;
    final resolved = const InferencePlanner().resolve(
      models: catalog,
      device: _device,
      backends: capabilities,
    );
    for (final candidate in resolved) {
      _preferredVariants.putIfAbsent(
        candidate.model.id,
        () => candidate.variant,
      );
      _preferredBackends.putIfAbsent(
        candidate.model.id,
        () => candidate.backend,
      );
    }
    return catalog;
  }

  ModelStatus _statusFor(CatalogEntry e) {
    final variant = _preferredVariants[e.id];
    if ((variant != null &&
            ModelPackageService.instance.byVariantId(variant.id)?.runnable ==
                true) ||
        ModelPackageService.instance.isModelRunnable(e.id) ||
        ModelDownloadService.instance.isDownloaded(e.id)) {
      return ModelStatus.loaded;
    }
    if ((variant != null &&
            ModelPackageService.instance.isDownloading(variant.id)) ||
        ModelDownloadService.instance.isDownloading(e.id)) {
      return ModelStatus.downloading;
    }
    return ModelStatus.catalog;
  }

  double? _progressFor(CatalogEntry e) {
    final variant = _preferredVariants[e.id];
    if (variant != null &&
        ModelPackageService.instance.isDownloading(variant.id)) {
      return ModelPackageService.instance.progressOf(variant.id);
    }
    return ModelDownloadService.instance.isDownloading(e.id)
        ? ModelDownloadService.instance.progressOf(e.id)
        : null;
  }

  bool _isSelected(AppState app, MockModel m) {
    if (m.id != null && m.id!.isNotEmpty) {
      return !app.isNetworkModelSelected && app.selectedModelId == m.id;
    }
    return app.selectedModel == m.name;
  }

  BackendKind? _backendForVariant(ModelVariant variant) {
    final supported = _capabilities
        .where((capability) => capability.supports(variant, _device.platform))
        .toList();
    if (supported.isEmpty) return null;
    final apple =
        _device.platform.startsWith('macos-') ||
        _device.platform.startsWith('ios-');
    supported.sort((a, b) {
      int score(BackendKind kind) => switch ((apple, kind)) {
        (true, BackendKind.mlx) => 3,
        (false, BackendKind.turboQuant) => 3,
        (_, BackendKind.llamaCpp) => 2,
        _ => 1,
      };
      return score(b.kind).compareTo(score(a.kind));
    });
    return supported.first.kind;
  }

  List<ModelVariant> _variantsForDevice(CatalogEntry entry) => entry.variants
      .where((variant) => variant.isActive)
      .where((variant) => _backendForVariant(variant) != null)
      .toList(growable: false);

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([
        ModelDownloadService.instance,
        ModelPackageService.instance,
        ImportedModelService.instance,
        LocalServerService.instance,
      ]),
      builder: (context, _) {
        return FutureBuilder<List<CatalogEntry>>(
          future: _catalogFuture,
          builder: (context, snapshot) {
            final app = AppScope.of(context);
            final q = widget.query.toLowerCase();
            final catalog = (snapshot.data ?? CatalogService.entries)
                .where(
                  (entry) =>
                      entry.status != 'deprecated' &&
                      (entry.variants.isNotEmpty ||
                          entry.downloadUrl.isNotEmpty),
                )
                .toList();
            final filteredCatalog = catalog
                .where((e) => q.isEmpty || e.matchesQuery(widget.query))
                .toList();
            final imported = ImportedModelService.instance.models
                .where(
                  (model) =>
                      q.isEmpty ||
                      model.name.toLowerCase().contains(q) ||
                      model.architecture.toLowerCase().contains(q) ||
                      model.format.toLowerCase().contains(q),
                )
                .toList();
            final onDevice = filteredCatalog
                .where(
                  (entry) =>
                      ModelPackageService.instance.isModelRunnable(entry.id) ||
                      (_preferredVariants[entry.id] != null &&
                          ModelPackageService.instance.isDownloading(
                            _preferredVariants[entry.id]!.id,
                          )) ||
                      ModelDownloadService.instance.isDownloaded(entry.id) ||
                      ModelDownloadService.instance.isDownloading(entry.id),
                )
                .toList();
            final available = filteredCatalog
                .where(
                  (entry) =>
                      !ModelPackageService.instance.isModelRunnable(entry.id) &&
                      !(_preferredVariants[entry.id] != null &&
                          ModelPackageService.instance.isDownloading(
                            _preferredVariants[entry.id]!.id,
                          )) &&
                      !ModelDownloadService.instance.isDownloaded(entry.id) &&
                      !ModelDownloadService.instance.isDownloading(entry.id),
                )
                .toList();

            if (widget.wide) {
              return _buildDesktopCatalog(
                context,
                app,
                filteredCatalog,
                imported,
                snapshot.hasData,
              );
            }

            const pad = EdgeInsets.fromLTRB(20, 0, 20, 16);

            return ListView(
              padding: pad,
              children: [
                if (imported.isNotEmpty) ...[
                  const _ListSectionLabel('IMPORTED BY YOU'),
                  for (final model in imported) ...[
                    _importedCard(context, app, model),
                    const SizedBox(height: 11),
                  ],
                ],
                if (onDevice.isNotEmpty) ...[
                  _ListSectionLabel('ON THIS DEVICE'),
                  for (final entry in onDevice) ...[
                    _catalogCard(context, app, entry),
                    const SizedBox(height: 11),
                  ],
                ],
                if (!widget.wide) ...[
                  const _NetworkStripCard(),
                  const SizedBox(height: 11),
                  if (!app.signedIn) const _LockedCard(compact: true),
                ],
                if (available.isNotEmpty) ...[
                  const SizedBox(height: 7),
                  _ListSectionLabel('CATALOG · ${available.length}'),
                  for (final e in available) ...[
                    _catalogCard(context, app, e),
                    const SizedBox(height: 11),
                  ],
                ] else if (!snapshot.hasData) ...[
                  const Center(
                    child: Padding(
                      padding: EdgeInsets.only(top: 32),
                      child: CircularProgressIndicator(color: AppColors.accent),
                    ),
                  ),
                ] else if (filteredCatalog.isEmpty) ...[
                  Center(
                    child: Padding(
                      padding: const EdgeInsets.only(top: 32),
                      child: Text(
                        CatalogService.lastError == null
                            ? 'No models match your search'
                            : 'Catalog unavailable · pull to retry',
                        style: AppText.grotesk(
                          13,
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildDesktopCatalog(
    BuildContext context,
    AppState app,
    List<CatalogEntry> catalog,
    List<ImportedModel> imported,
    bool loaded,
  ) {
    if (!loaded && catalog.isEmpty) {
      return const Center(
        child: CircularProgressIndicator(color: AppColors.accent),
      );
    }
    if (catalog.isEmpty) {
      return Center(
        child: Text(
          CatalogService.lastError == null
              ? 'No models match your search'
              : 'Catalog unavailable · try again shortly',
          style: AppText.grotesk(13, color: AppColors.textSecondary),
        ),
      );
    }

    CatalogEntry selected = catalog.first;
    for (final entry in catalog) {
      if (entry.id == _selectedEntryId) {
        selected = entry;
        break;
      }
    }
    final selectedVariant = _preferredVariants[selected.id];
    final deviceVariants = _variantsForDevice(selected);

    return LayoutBuilder(
      builder: (context, constraints) {
        final listWidth = (constraints.maxWidth * 0.34).clamp(300.0, 390.0);
        return Container(
          margin: const EdgeInsets.only(bottom: 24),
          decoration: BoxDecoration(
            color: AppColors.bgElevated,
            border: Border.all(color: AppColors.stroke),
            borderRadius: BorderRadius.circular(18),
          ),
          clipBehavior: Clip.antiAlias,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: listWidth,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(18, 16, 18, 12),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              'MODEL CATALOG',
                              style: AppText.sectionHeader(size: 10),
                            ),
                          ),
                          Text(
                            '${catalog.length}',
                            style: AppText.mono(10, color: AppColors.textMuted),
                          ),
                        ],
                      ),
                    ),
                    const Divider(height: 1, color: AppColors.strokeSoft),
                    Expanded(
                      child: ListView(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        children: [
                          if (imported.isNotEmpty) ...[
                            const Padding(
                              padding: EdgeInsets.fromLTRB(18, 6, 18, 5),
                              child: _ListSectionLabel('IMPORTED BY YOU'),
                            ),
                            for (final model in imported)
                              _DesktopImportedTile(
                                model: model,
                                selected:
                                    !app.isNetworkModelSelected &&
                                    app.selectedModelId == model.id,
                                onTap: () => app.selectModel(
                                  model.name,
                                  model.quantization.isEmpty
                                      ? model.format.toUpperCase()
                                      : model.quantization,
                                  id: model.id,
                                  variantId: model.variantId,
                                ),
                              ),
                            const Padding(
                              padding: EdgeInsets.fromLTRB(18, 15, 18, 5),
                              child: _ListSectionLabel('CURATED CATALOG'),
                            ),
                          ],
                          for (final entry in catalog)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 2),
                              child: _DesktopCatalogTile(
                                entry: entry,
                                variant: _preferredVariants[entry.id],
                                status: _statusFor(entry),
                                selected: entry.id == selected.id,
                                onTap: () =>
                                    setState(() => _selectedEntryId = entry.id),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const VerticalDivider(
                width: 1,
                thickness: 1,
                color: AppColors.stroke,
              ),
              Expanded(
                child: _DesktopModelDetail(
                  entry: selected,
                  selectedVariant: selectedVariant,
                  deviceVariants: deviceVariants,
                  backend: selectedVariant == null
                      ? null
                      : _backendForVariant(selectedVariant),
                  status: _statusFor(selected),
                  progress: _progressFor(selected),
                  selectedInApp:
                      !app.isNetworkModelSelected &&
                      app.selectedModelId == selected.id,
                  onSelectVariant: (variant) {
                    _preferredVariants[selected.id] = variant;
                    final backend = _backendForVariant(variant);
                    if (backend != null) {
                      _preferredBackends[selected.id] = backend;
                    }
                    setState(() {});
                  },
                  onDownload: selectedVariant == null
                      ? null
                      : () =>
                            _download(context, app, selected, selectedVariant),
                  onUpdate:
                      selectedVariant != null &&
                          ModelPackageService.instance.hasUpdate(
                            selectedVariant,
                          )
                      ? () => _download(
                          context,
                          app,
                          selected,
                          selectedVariant,
                          updating: true,
                        )
                      : null,
                  onUse: selectedVariant == null
                      ? null
                      : () => app.selectModel(
                          selected.name,
                          selectedVariant.quantization,
                          id: selected.id,
                          variantId: selectedVariant.id,
                        ),
                  onCancel: selectedVariant == null
                      ? null
                      : () => ModelPackageService.instance.cancelDownload(
                          selectedVariant.id,
                        ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _importedCard(
    BuildContext context,
    AppState app,
    ImportedModel imported,
  ) {
    final detail = [
      if (imported.parameterLabel.isNotEmpty) imported.parameterLabel,
      if (imported.quantization.isNotEmpty) imported.quantization,
      imported.format.toUpperCase(),
      imported.backend,
      imported.reference ? 'REFERENCED' : formatBytes(imported.sizeBytes),
    ].join(' · ');
    return _LocalModelCard(
      model: MockModel(
        imported.name,
        imported.name.isEmpty ? '?' : imported.name[0].toUpperCase(),
        detail,
        id: imported.id,
        status: ModelStatus.loaded,
        accent: app.selectedModelId == imported.id,
      ),
      shared: LocalServerService.instance.sharedModelIds.contains(imported.id),
      onTap: () => app.selectModel(
        imported.name,
        imported.quantization.isEmpty
            ? imported.format.toUpperCase()
            : imported.quantization,
        id: imported.id,
        variantId: imported.variantId,
      ),
      onDelete: () => _deleteImported(context, app, imported),
    );
  }

  Future<void> _deleteImported(
    BuildContext context,
    AppState app,
    ImportedModel imported,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Remove ${imported.name}?'),
        content: Text(
          imported.reference
              ? 'This removes the model from Erebrus. The original files will not be deleted.'
              : 'This deletes Erebrus’s private copy. The original source file is not affected.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('CANCEL'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('REMOVE'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (InferenceService.instance.activeModelId == imported.id) {
      await InferenceService.instance.unload();
    }
    await ImportedModelService.instance.remove(imported.id);
    app.clearSelectedModelIf(imported.id);
  }

  Widget _catalogCard(BuildContext context, AppState app, CatalogEntry entry) {
    final status = _statusFor(entry);
    final variant = _preferredVariants[entry.id];
    final packagedDownload =
        variant != null &&
        ModelPackageService.instance.isDownloading(variant.id);
    final received = packagedDownload
        ? ModelPackageService.instance.receivedBytesOf(variant.id)
        : ModelDownloadService.instance.receivedBytesOf(entry.id);
    final total = packagedDownload
        ? ModelPackageService.instance.totalBytesOf(variant.id)
        : ModelDownloadService.instance.totalBytesOf(entry.id);
    final quant = variant?.quantization.isNotEmpty == true
        ? variant!.quantization
        : entry.quant;
    final backend = _preferredBackends[entry.id];
    final backendLabel = backend?.catalogName ?? 'llama.cpp';
    final updateAvailable =
        variant != null && ModelPackageService.instance.hasUpdate(variant);
    final deviceVariants = _variantsForDevice(entry);
    final model = MockModel(
      entry.name,
      entry.letter,
      '${entry.spec} · ${variant?.format.toUpperCase() ?? 'GGUF'} · $backendLabel',
      id: entry.id,
      status: status,
      progress: _progressFor(entry),
      progressLabel: status == ModelStatus.downloading
          ? '${formatBytes(received)} / ${formatBytes(total > 0 ? total : entry.sizeBytes)}'
          : null,
      accent: _isSelected(
        app,
        MockModel(entry.name, entry.letter, entry.spec, id: entry.id),
      ),
    );
    return _LocalModelCard(
      model: model,
      shared: LocalServerService.instance.sharedModelIds.contains(entry.id),
      onTap: status == ModelStatus.loaded
          ? () => app.selectModel(
              entry.name,
              quant,
              id: entry.id,
              variantId: variant?.id,
            )
          : null,
      onUse: status == ModelStatus.loaded
          ? () => app.selectModel(
              entry.name,
              quant,
              id: entry.id,
              variantId: variant?.id,
            )
          : null,
      onDownload: status == ModelStatus.catalog
          ? () => _download(context, app, entry, variant)
          : null,
      onUpdate: updateAvailable
          ? () => _download(context, app, entry, variant, updating: true)
          : null,
      variantCount: deviceVariants.length,
      onVariants: deviceVariants.isEmpty
          ? null
          : () => _showVariants(context, app, entry, deviceVariants),
      onCancel: status == ModelStatus.downloading
          ? () {
              if (variant != null &&
                  ModelPackageService.instance.isDownloading(variant.id)) {
                ModelPackageService.instance.cancelDownload(variant.id);
              } else {
                ModelDownloadService.instance.cancelDownload(entry.id);
              }
            }
          : null,
    );
  }

  Future<void> _showVariants(
    BuildContext context,
    AppState app,
    CatalogEntry entry,
    List<ModelVariant> variants,
  ) async {
    final selected = await showModalBottomSheet<ModelVariant>(
      context: context,
      backgroundColor: AppColors.surface,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.75,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      entry.name,
                      style: AppText.grotesk(20, weight: FontWeight.w600),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'CHOOSE AN OPTIMIZED PACKAGE FOR THIS DEVICE',
                      style: AppText.mono(
                        10,
                        color: AppColors.textMuted,
                        lsEm: 0.08,
                      ),
                    ),
                  ],
                ),
              ),
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
                  itemCount: variants.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (_, index) {
                    final candidate = variants[index];
                    final backend = _backendForVariant(candidate);
                    final installed = ModelPackageService.instance.byVariantId(
                      candidate.id,
                    );
                    final isSelected =
                        app.selectedModelVariantId == candidate.id;
                    return ListTile(
                      enabled: backend != null,
                      selected: isSelected,
                      leading: Icon(
                        candidate.format == 'mlx'
                            ? Symbols.memory
                            : Symbols.deployed_code,
                        color: isSelected
                            ? AppColors.accent
                            : AppColors.textSecondary,
                      ),
                      title: Text(
                        '${candidate.format.toUpperCase()} · ${candidate.quantization}',
                        style: AppText.grotesk(14, weight: FontWeight.w600),
                      ),
                      subtitle: Text(
                        '${candidate.provenance.label} · '
                        '${candidate.provenance.publisher} · '
                        '${backend?.catalogName ?? 'UNAVAILABLE'} · '
                        '${formatBytes(candidate.sizeBytes)}',
                        style: AppText.mono(9.5, color: AppColors.textMuted),
                      ),
                      trailing: installed?.runnable == true
                          ? Icon(
                              isSelected
                                  ? Symbols.check_circle
                                  : Symbols.play_arrow,
                              color: AppColors.accent,
                            )
                          : const Icon(Symbols.download, size: 20),
                      onTap: backend == null
                          ? null
                          : () => Navigator.pop(sheetContext, candidate),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (selected == null || !context.mounted) return;
    if (ModelPackageService.instance.byVariantId(selected.id)?.runnable ==
        true) {
      app.selectModel(
        entry.name,
        selected.quantization,
        id: entry.id,
        variantId: selected.id,
      );
      return;
    }
    await _download(context, app, entry, selected);
  }

  Future<void> _download(
    BuildContext context,
    AppState app,
    CatalogEntry entry,
    ModelVariant? variant, {
    bool updating = false,
  }) async {
    try {
      if (variant != null) {
        _preferredVariants[entry.id] = variant;
        final backend = _backendForVariant(variant);
        if (backend != null) _preferredBackends[entry.id] = backend;
        if (mounted) setState(() {});
      }
      if (variant == null ||
          !variant.files
              .where((artifact) => artifact.required)
              .every((artifact) => artifact.sha256.isNotEmpty)) {
        final ok = await ModelDownloadService.instance.download(entry);
        if (!ok) throw StateError('Legacy model download failed');
        return;
      }
      if (updating) {
        await InferenceService.instance.unload();
        await ModelPackageService.instance.updateVariant(variant);
      } else {
        await ModelPackageService.instance.downloadVariant(variant);
      }
      final packagePath = await ModelPackageService.instance.packagePath(
        variant.id,
      );
      if (packagePath == null) {
        throw StateError('Verified package path is unavailable');
      }
      final backend = _backendForVariant(variant);
      if (backend == null) {
        throw StateError(
          'No operational backend can run ${variant.id} on ${_device.platform}',
        );
      }
      final memoryPlan = const InferenceMemoryPolicy().plan(
        device: _device,
        backend: backend,
      );
      final readiness = await InferenceReadinessService().verify(
        variant: variant,
        packagePath: packagePath,
        contextSize: memoryPlan.contextSize,
      );
      if (!readiness.runnable) {
        if (updating) {
          await ModelPackageService.instance.rollback(variant.id);
        } else {
          await ModelPackageService.instance.markUnrunnable(
            variant.id,
            readiness.failureCode,
          );
        }
        throw StateError(readiness.reason);
      }
      app.selectModel(
        entry.name,
        variant.quantization,
        id: entry.id,
        variantId: variant.id,
      );
    } on Object catch (error) {
      if (error is ModelPackageException &&
          error.code == 'download_cancelled') {
        return;
      }
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Model install failed: $error'),
          action: StorageService.supportsAppPermissionSettings
              ? SnackBarAction(
                  label: 'SETTINGS',
                  onPressed: StorageService.instance.openSettings,
                )
              : null,
        ),
      );
    }
  }
}

class _DesktopImportedTile extends StatelessWidget {
  const _DesktopImportedTile({
    required this.model,
    required this.selected,
    required this.onTap,
  });

  final ImportedModel model;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(8, 0, 8, 2),
    child: Material(
      color: selected ? AppColors.accent.withA(0.12) : Colors.transparent,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 10),
          child: Row(
            children: [
              LetterTile(
                model.name.isEmpty ? '?' : model.name[0].toUpperCase(),
                size: 34,
                radius: 9,
                fontSize: 12,
                accent: selected,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      model.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.grotesk(13, weight: FontWeight.w600),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      [
                        model.format.toUpperCase(),
                        model.quantization,
                        formatBytes(model.sizeBytes),
                      ].where((part) => part.isNotEmpty).join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.mono(9, color: AppColors.textMuted),
                    ),
                  ],
                ),
              ),
              const Icon(
                Symbols.folder_special,
                size: 16,
                color: AppColors.textMuted,
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _DesktopCatalogTile extends StatelessWidget {
  const _DesktopCatalogTile({
    required this.entry,
    required this.variant,
    required this.status,
    required this.selected,
    required this.onTap,
  });

  final CatalogEntry entry;
  final ModelVariant? variant;
  final ModelStatus status;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final formats = entry.variants
        .map((candidate) => candidate.format.toUpperCase())
        .toSet()
        .join(' · ');
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Material(
        color: selected ? AppColors.accent.withA(0.12) : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 12),
            decoration: BoxDecoration(
              border: Border.all(
                color: selected
                    ? AppColors.accent.withA(0.45)
                    : Colors.transparent,
              ),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                LetterTile(
                  entry.letter,
                  size: 38,
                  radius: 10,
                  fontSize: 13,
                  accent: selected,
                ),
                const SizedBox(width: 11),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              entry.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: AppText.grotesk(
                                13.5,
                                weight: FontWeight.w600,
                              ),
                            ),
                          ),
                          if (entry.featured)
                            const Icon(
                              Symbols.kid_star,
                              size: 15,
                              color: AppColors.warn,
                            ),
                        ],
                      ),
                      const SizedBox(height: 3),
                      Text(
                        entry.publisher.isNotEmpty
                            ? entry.publisher
                            : entry.family,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.grotesk(
                          11.5,
                          color: AppColors.textTertiary,
                        ),
                      ),
                      const SizedBox(height: 5),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              [
                                if (entry.parameterLabel.isNotEmpty)
                                  entry.parameterLabel,
                                if (formats.isNotEmpty) formats,
                                if (variant?.quantization.isNotEmpty == true)
                                  variant!.quantization,
                              ].join(' · '),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: AppText.mono(
                                9,
                                color: AppColors.textMuted,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          _StatusDot(status: status),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.status});

  final ModelStatus status;

  @override
  Widget build(BuildContext context) {
    final (color, label) = switch (status) {
      ModelStatus.loaded => (AppColors.success, 'READY'),
      ModelStatus.downloading => (AppColors.accentHi, 'LOADING'),
      ModelStatus.idle => (AppColors.success, 'READY'),
      ModelStatus.catalog => (AppColors.textMuted, 'AVAILABLE'),
    };
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 5),
        Text(label, style: AppText.mono(8.5, color: color)),
      ],
    );
  }
}

class _DesktopModelDetail extends StatelessWidget {
  const _DesktopModelDetail({
    required this.entry,
    required this.selectedVariant,
    required this.deviceVariants,
    required this.backend,
    required this.status,
    required this.progress,
    required this.selectedInApp,
    required this.onSelectVariant,
    required this.onDownload,
    required this.onUpdate,
    required this.onUse,
    required this.onCancel,
  });

  final CatalogEntry entry;
  final ModelVariant? selectedVariant;
  final List<ModelVariant> deviceVariants;
  final BackendKind? backend;
  final ModelStatus status;
  final double? progress;
  final bool selectedInApp;
  final ValueChanged<ModelVariant> onSelectVariant;
  final VoidCallback? onDownload;
  final VoidCallback? onUpdate;
  final VoidCallback? onUse;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    final formats = entry.variants
        .map((variant) => variant.format.toUpperCase())
        .toSet()
        .toList();
    final selectedInstalled =
        selectedVariant != null &&
        ModelPackageService.instance
                .byVariantId(selectedVariant!.id)
                ?.runnable ==
            true;
    final selectedDownloading =
        selectedVariant != null &&
        ModelPackageService.instance.isDownloading(selectedVariant!.id);

    return ListView(
      padding: const EdgeInsets.fromLTRB(26, 22, 26, 30),
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            LetterTile(
              entry.letter,
              size: 48,
              radius: 13,
              fontSize: 17,
              accent: true,
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    entry.name,
                    style: AppText.grotesk(22, weight: FontWeight.w600),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    entry.publisher.isNotEmpty ? entry.publisher : entry.family,
                    style: AppText.grotesk(
                      12.5,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            if (entry.featured)
              const _DetailBadge(
                label: 'STAFF PICK',
                icon: Symbols.kid_star,
                color: AppColors.warn,
              ),
          ],
        ),
        const SizedBox(height: 18),
        _DetailSurface(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                entry.description.isNotEmpty
                    ? entry.description
                    : 'A curated model package for private local inference.',
                style: AppText.grotesk(
                  15,
                  weight: FontWeight.w500,
                  color: AppColors.textBody,
                  height: 1.45,
                ),
              ),
              const SizedBox(height: 16),
              const Divider(height: 1, color: AppColors.strokeSoft),
              const SizedBox(height: 14),
              Wrap(
                spacing: 20,
                runSpacing: 12,
                children: [
                  _MetaValue(
                    label: 'PARAMS',
                    value: entry.parameterLabel.isNotEmpty
                        ? entry.parameterLabel
                        : '${entry.parameterB}B',
                  ),
                  if (entry.architecture.isNotEmpty)
                    _MetaValue(label: 'ARCH', value: entry.architecture),
                  if (entry.recommendedContextLength > 0)
                    _MetaValue(
                      label: 'CONTEXT',
                      value: _formatContext(entry.recommendedContextLength),
                    ),
                  _MetaValue(label: 'FORMAT', value: formats.join(' / ')),
                  if (entry.licenseId.isNotEmpty)
                    _MetaValue(
                      label: 'LICENSE',
                      value: entry.licenseId.toUpperCase(),
                    ),
                ],
              ),
              if (entry.capabilities.isNotEmpty) ...[
                const SizedBox(height: 16),
                Wrap(
                  spacing: 7,
                  runSpacing: 7,
                  children: entry.capabilities
                      .map((capability) => _CapabilityChip(capability))
                      .toList(),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 22),
        Text(
          'Download options',
          style: AppText.grotesk(17, weight: FontWeight.w600),
        ),
        const SizedBox(height: 10),
        if (deviceVariants.isEmpty)
          const _DetailSurface(child: _EmptyVariantMessage())
        else
          _DetailSurface(
            padding: const EdgeInsets.all(10),
            child: Column(
              children: [
                for (final variant in deviceVariants) ...[
                  _VariantChoice(
                    variant: variant,
                    selected: variant.id == selectedVariant?.id,
                    installed:
                        ModelPackageService.instance
                            .byVariantId(variant.id)
                            ?.runnable ==
                        true,
                    onTap: () => onSelectVariant(variant),
                  ),
                  if (variant != deviceVariants.last) const SizedBox(height: 7),
                ],
                if (selectedVariant != null) ...[
                  const SizedBox(height: 12),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Row(
                      children: [
                        if (entry.supportsGpuOffload)
                          const _DetailBadge(
                            label: 'GPU OFFLOAD SUPPORTED',
                            icon: Symbols.bolt,
                            color: AppColors.success,
                          ),
                        const Spacer(),
                        Text(
                          backend?.catalogName.toUpperCase() ?? '',
                          style: AppText.mono(9.5, color: AppColors.textMuted),
                        ),
                        const SizedBox(width: 12),
                        if (selectedDownloading)
                          OutlinedButton.icon(
                            onPressed: onCancel,
                            icon: const Icon(Symbols.close, size: 17),
                            label: Text(
                              'CANCEL ${((progress ?? 0) * 100).round()}%',
                            ),
                          )
                        else if (onUpdate != null)
                          FilledButton.icon(
                            onPressed: onUpdate,
                            icon: const Icon(
                              Symbols.system_update_alt,
                              size: 17,
                            ),
                            label: const Text('UPDATE'),
                          )
                        else if (selectedInstalled)
                          FilledButton.icon(
                            onPressed: onUse,
                            icon: Icon(
                              selectedInApp
                                  ? Symbols.check
                                  : Symbols.play_arrow,
                              size: 17,
                            ),
                            label: Text(selectedInApp ? 'SELECTED' : 'USE'),
                          )
                        else
                          FilledButton.icon(
                            onPressed: onDownload,
                            icon: const Icon(Symbols.download, size: 17),
                            label: Text(
                              'DOWNLOAD · ${formatBytes(selectedVariant!.sizeBytes)}',
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        const SizedBox(height: 22),
        Text(
          'About this model',
          style: AppText.grotesk(17, weight: FontWeight.w600),
        ),
        const SizedBox(height: 10),
        _DetailSurface(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (entry.bestFor.isNotEmpty)
                _DetailList(title: 'BEST FOR', items: entry.bestFor),
              if (entry.bestFor.isNotEmpty && entry.limitations.isNotEmpty)
                const SizedBox(height: 18),
              if (entry.limitations.isNotEmpty)
                _DetailList(
                  title: 'LIMITATIONS',
                  items: entry.limitations,
                  color: AppColors.warn,
                ),
              if (entry.bestFor.isNotEmpty || entry.limitations.isNotEmpty)
                const SizedBox(height: 18),
              _ProvenanceSummary(entry: entry, variant: selectedVariant),
            ],
          ),
        ),
      ],
    );
  }
}

class _DetailSurface extends StatelessWidget {
  const _DetailSurface({required this.child, this.padding});

  final Widget child;
  final EdgeInsets? padding;

  @override
  Widget build(BuildContext context) => Container(
    padding: padding ?? const EdgeInsets.all(18),
    decoration: BoxDecoration(
      color: AppColors.surface,
      border: Border.all(color: AppColors.strokeSoft),
      borderRadius: BorderRadius.circular(15),
    ),
    child: child,
  );
}

class _MetaValue extends StatelessWidget {
  const _MetaValue({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(
        label,
        style: AppText.mono(
          9,
          weight: FontWeight.w600,
          color: AppColors.textFaint,
        ),
      ),
      const SizedBox(width: 7),
      Text(
        value,
        style: AppText.mono(
          10.5,
          weight: FontWeight.w600,
          color: AppColors.textBody,
        ),
      ),
    ],
  );
}

class _DetailBadge extends StatelessWidget {
  const _DetailBadge({
    required this.label,
    required this.icon,
    required this.color,
  });

  final String label;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
    decoration: BoxDecoration(
      color: color.withA(0.09),
      border: Border.all(color: color.withA(0.28)),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 6),
        Text(
          label,
          style: AppText.mono(9, weight: FontWeight.w600, color: color),
        ),
      ],
    ),
  );
}

class _CapabilityChip extends StatelessWidget {
  const _CapabilityChip(this.capability);

  final String capability;

  @override
  Widget build(BuildContext context) {
    final normalized = capability.toLowerCase();
    final color = normalized.contains('vision')
        ? AppColors.warn
        : normalized.contains('reason')
        ? AppColors.success
        : normalized.contains('tool') || normalized.contains('code')
        ? AppColors.orgPurple
        : AppColors.accentHi;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
      decoration: BoxDecoration(
        color: color.withA(0.08),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        capability.replaceAll('_', ' ').toUpperCase(),
        style: AppText.mono(8.5, weight: FontWeight.w600, color: color),
      ),
    );
  }
}

class _VariantChoice extends StatelessWidget {
  const _VariantChoice({
    required this.variant,
    required this.selected,
    required this.installed,
    required this.onTap,
  });

  final ModelVariant variant;
  final bool selected;
  final bool installed;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
    color: selected ? AppColors.accent.withA(0.08) : AppColors.surface2,
    borderRadius: BorderRadius.circular(11),
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(11),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 12),
        decoration: BoxDecoration(
          border: Border.all(
            color: selected
                ? AppColors.accent.withA(0.45)
                : AppColors.strokeSoft,
          ),
          borderRadius: BorderRadius.circular(11),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
              decoration: BoxDecoration(
                color: AppColors.surface3,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                variant.format.toUpperCase(),
                style: AppText.mono(
                  9,
                  weight: FontWeight.w600,
                  color: AppColors.textBody,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                [
                  variant.quantization,
                  if (variant.provenance.publisher.isNotEmpty)
                    variant.provenance.publisher,
                ].join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.grotesk(12.5, weight: FontWeight.w500),
              ),
            ),
            if (installed) ...[
              const Icon(
                Symbols.check_circle,
                size: 16,
                color: AppColors.success,
              ),
              const SizedBox(width: 8),
            ],
            Text(
              formatBytes(variant.sizeBytes),
              style: AppText.mono(9.5, color: AppColors.textMuted),
            ),
          ],
        ),
      ),
    ),
  );
}

class _EmptyVariantMessage extends StatelessWidget {
  const _EmptyVariantMessage();

  @override
  Widget build(BuildContext context) => Row(
    children: [
      const Icon(Symbols.info, color: AppColors.warn),
      const SizedBox(width: 10),
      Expanded(
        child: Text(
          'No catalog package is compatible with this device and its active runtimes.',
          style: AppText.grotesk(12.5, color: AppColors.textSecondary),
        ),
      ),
    ],
  );
}

class _DetailList extends StatelessWidget {
  const _DetailList({
    required this.title,
    required this.items,
    this.color = AppColors.textSecondary,
  });

  final String title;
  final List<String> items;
  final Color color;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(title, style: AppText.sectionHeader(size: 9.5)),
      const SizedBox(height: 8),
      for (final item in items)
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 7),
                child: Container(
                  width: 4,
                  height: 4,
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  item,
                  style: AppText.grotesk(
                    12.5,
                    color: AppColors.textSecondary,
                    height: 1.4,
                  ),
                ),
              ),
            ],
          ),
        ),
    ],
  );
}

class _ProvenanceSummary extends StatelessWidget {
  const _ProvenanceSummary({required this.entry, required this.variant});

  final CatalogEntry entry;
  final ModelVariant? variant;

  @override
  Widget build(BuildContext context) {
    final provenance = variant?.provenance;
    final verification = entry.runtimeVerification
        .replaceAll('_', ' ')
        .toUpperCase();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('SOURCE & VERIFICATION', style: AppText.sectionHeader(size: 9.5)),
        const SizedBox(height: 9),
        if (provenance?.repositoryId.isNotEmpty == true)
          Text(
            provenance!.repositoryId,
            style: AppText.mono(10.5, color: AppColors.textBody),
          ),
        if (provenance != null) ...[
          const SizedBox(height: 5),
          Text(
            '${provenance.label} · ${provenance.verification.replaceAll('_', ' ').toUpperCase()}',
            style: AppText.mono(9, color: AppColors.textMuted),
          ),
        ],
        if (verification.isNotEmpty) ...[
          const SizedBox(height: 5),
          Text(verification, style: AppText.mono(9, color: AppColors.success)),
        ],
        if (entry.licenseName.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text(
            '${entry.licenseName}${entry.commercialUse ? ' · COMMERCIAL USE ALLOWED' : ''}',
            style: AppText.mono(9.5, color: AppColors.textSecondary),
          ),
        ],
      ],
    );
  }
}

String _formatContext(int tokens) {
  if (tokens >= 1000000) return '${(tokens / 1000000).toStringAsFixed(1)}M';
  if (tokens >= 1000) {
    final value = tokens / 1000;
    return '${value == value.roundToDouble() ? value.round() : value.toStringAsFixed(1)}K';
  }
  return '$tokens';
}

class _ListSectionLabel extends StatelessWidget {
  const _ListSectionLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(left: 4, bottom: 8),
    child: Text(
      text,
      style: AppText.mono(
        10,
        weight: FontWeight.w500,
        color: AppColors.textFaint,
        lsEm: 0.12,
      ),
    ),
  );
}

class _LocalModelCard extends StatelessWidget {
  const _LocalModelCard({
    required this.model,
    this.onTap,
    this.onUse,
    this.onDownload,
    this.onUpdate,
    this.onVariants,
    this.onCancel,
    this.onDelete,
    this.variantCount = 0,
    this.shared = false,
  });

  final MockModel model;
  final VoidCallback? onTap;
  final VoidCallback? onUse;
  final VoidCallback? onDownload;
  final VoidCallback? onUpdate;
  final VoidCallback? onVariants;
  final VoidCallback? onCancel;
  final VoidCallback? onDelete;
  final int variantCount;
  final bool shared;

  @override
  Widget build(BuildContext context) {
    final canTap =
        model.status != ModelStatus.downloading &&
        (onTap ?? onUse ?? onDownload ?? onUpdate) != null;
    return GestureDetector(
      onTap: canTap ? (onTap ?? onUse ?? onDownload ?? onUpdate) : null,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.all(15),
        decoration: BoxDecoration(
          color: AppColors.surface,
          border: Border.all(
            color: model.accent ? AppColors.accent : AppColors.stroke,
            width: model.accent ? 1.5 : 1,
          ),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          children: [
            Row(
              children: [
                LetterTile(
                  model.letter,
                  size: 36,
                  radius: 10,
                  fontSize: 13,
                  accent: model.accent,
                ),
                const SizedBox(width: 12),
                Expanded(
                  // The action chip stays beside the name when there is room
                  // and drops under it on narrow phones, so names never wrap.
                  child: AdaptiveRow(
                    leading: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          model.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppText.grotesk(14.5, weight: FontWeight.w600),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          model.spec,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppText.mono(
                            10,
                            color: AppColors.textTertiary,
                          ),
                        ),
                      ],
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        switch (model.status) {
                          ModelStatus.loaded =>
                            onUpdate != null
                                ? AccentChip(
                                    'UPDATE',
                                    icon: Symbols.system_update_alt,
                                    onTap: onUpdate!,
                                  )
                                : _MemoryBadge(modelId: model.id ?? ''),
                          ModelStatus.idle =>
                            onUse != null
                                ? AccentChip('USE', onTap: onUse!)
                                : const StatusBadge('READY'),
                          ModelStatus.downloading => IconButton(
                            tooltip: 'Cancel download',
                            visualDensity: VisualDensity.compact,
                            onPressed: onCancel,
                            icon: const Icon(
                              Symbols.close,
                              size: 18,
                              color: AppColors.textSecondary,
                            ),
                          ),
                          ModelStatus.catalog =>
                            onDownload != null
                                ? AccentChip(
                                    'GET',
                                    icon: Symbols.download,
                                    onTap: onDownload!,
                                  )
                                : const StatusBadge('CATALOG'),
                        },
                        if (onDelete != null) ...[
                          const SizedBox(width: 4),
                          IconButton(
                            tooltip: 'Remove imported model',
                            visualDensity: VisualDensity.compact,
                            onPressed: onDelete,
                            icon: const Icon(
                              Symbols.delete_outline,
                              size: 18,
                              color: AppColors.textMuted,
                            ),
                          ),
                        ],
                      ],
                    ),
                    gap: 10,
                    stackedGap: 8,
                    minLeadingWidth: 170,
                    stackedAlignment: AlignmentDirectional.centerEnd,
                  ),
                ),
              ],
            ),
            if (model.status == ModelStatus.downloading) ...[
              const SizedBox(height: 11),
              EreProgressBar(value: model.progress ?? 0),
              const SizedBox(height: 7),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'DOWNLOADING · ${((model.progress ?? 0) * 100).round()}%',
                    style: AppText.mono(
                      10,
                      weight: FontWeight.w600,
                      color: AppColors.accentHi,
                    ),
                  ),
                  Text(
                    model.progressLabel ?? '',
                    style: AppText.mono(10, color: AppColors.textMuted),
                  ),
                ],
              ),
            ],
            if (shared) ...[
              const SizedBox(height: 10),
              Row(
                children: [
                  const Icon(Symbols.wifi, size: 14, color: AppColors.success),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Text(
                      '${model.name.toUpperCase()} IS SHARED ON YOUR LOCAL NETWORK',
                      style: AppText.mono(
                        9.5,
                        weight: FontWeight.w600,
                        color: AppColors.success,
                        lsEm: 0.04,
                      ),
                    ),
                  ),
                ],
              ),
            ],
            if (variantCount > 1 && onVariants != null) ...[
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerLeft,
                child: GestureDetector(
                  onTap: onVariants,
                  child: Text(
                    '$variantCount PACKAGES AVAILABLE · CHOOSE',
                    style: AppText.mono(
                      10,
                      weight: FontWeight.w600,
                      color: AppColors.accent,
                      lsEm: 0.06,
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Mobile LOCAL tab: summary strip linking to the NETWORK tab.
class _NetworkStripCard extends StatelessWidget {
  const _NetworkStripCard();

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: NodeDiscoveryService.instance,
      builder: (context, _) {
        final discovered = NodeDiscoveryService.instance.nodes;
        final count = discovered.length;
        final modelCount = discovered.fold<int>(
          0,
          (sum, node) => sum + node.models.length,
        );
        final subtitle = discovered.isEmpty
            ? (NodeDiscoveryService.instance.lastError != null
                  ? NodeDiscoveryService.instance.lastError!.toUpperCase()
                  : NodeDiscoveryService.instance.isRunning
                  ? 'SCANNING _EREBRUSAI._TCP'
                  : 'DISCOVERY IS NOT RUNNING')
            : '${discovered.map((n) => n.name.toUpperCase()).take(2).join(' · ')} · $modelCount MODELS';
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 14),
          decoration: BoxDecoration(
            color: AppColors.success.withA(0.05),
            border: Border.all(color: AppColors.success.withA(0.25)),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            children: [
              const Icon(Symbols.wifi, size: 20, color: AppColors.success),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      count == 0
                          ? 'No Erebrus nodes discovered'
                          : '$count node${count == 1 ? '' : 's'} on your network',
                      style: AppText.grotesk(13.5, weight: FontWeight.w600),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.mono(10, color: AppColors.textMuted),
                    ),
                  ],
                ),
              ),
              const Icon(
                Symbols.chevron_right,
                size: 18,
                color: AppColors.success,
              ),
            ],
          ),
        );
      },
    );
  }
}

// ─── NETWORK tab ─────────────────────────────────────────────────────────────

class _NetworkList extends StatelessWidget {
  const _NetworkList({
    required this.wide,
    required this.query,
    this.onOpenChat,
  });

  final bool wide;
  final String query;
  final VoidCallback? onOpenChat;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([
        NodeDiscoveryService.instance,
        ConnectionService.instance,
      ]),
      builder: (context, _) {
        final app = AppScope.of(context);
        final q = query.toLowerCase();
        final nodes = NodeDiscoveryService.instance.nodes;

        final filteredNodes = nodes.where((n) {
          if (q.isEmpty) return true;
          return n.name.toLowerCase().contains(q) ||
              n.models.any((m) => m.name.toLowerCase().contains(q));
        }).toList();

        final filteredConnections = ConnectionService
            .instance
            .enabledConnections
            .where(
              (connection) =>
                  q.isEmpty ||
                  connection.name.toLowerCase().contains(q) ||
                  connection.modelIds.any((id) => id.toLowerCase().contains(q)),
            )
            .toList();

        final filteredOrgModels = app.orgModels.where((m) {
          if (q.isEmpty) return true;
          return m.name.toLowerCase().contains(q) ||
              (m.quant?.toLowerCase().contains(q) ?? false) ||
              (m.size?.toLowerCase().contains(q) ?? false);
        }).toList();

        final pad = wide
            ? const EdgeInsets.only(bottom: 24)
            : const EdgeInsets.fromLTRB(20, 0, 20, 16);

        final children = <Widget>[
          if (NodeDiscoveryService.instance.lastError != null) ...[
            _DiscoveryErrorCard(
              message: NodeDiscoveryService.instance.lastError!,
            ),
            const SizedBox(height: 14),
          ],
          for (final connection in filteredConnections) ...[
            ConnectionModelsCard(
              connection: connection,
              onUse: onOpenChat,
              onEdit: () =>
                  openSettingsSection(context, SettingsSection.connections),
            ),
            const SizedBox(height: 14),
          ],
          for (final node in filteredNodes) ...[
            _NodeCard(node: node, onOpenChat: onOpenChat),
            const SizedBox(height: 14),
          ],
          if (filteredConnections.isEmpty && q.isEmpty) ...[
            _AddConnectionHint(
              onTap: () =>
                  openSettingsSection(context, SettingsSection.connections),
            ),
            const SizedBox(height: 14),
          ],
          if (app.signedIn) ...[
            if (filteredOrgModels.isNotEmpty)
              _OrgModelsCard(models: filteredOrgModels, wide: wide)
            else if (query.isNotEmpty)
              _emptyMessage('No matching workspace models')
            else if (app.orgState.isLoading)
              _emptyMessage('Loading workspace models…')
            else if (app.orgState.error != null)
              _emptyMessage('Workspace models unavailable')
            else
              _emptyMessage('No models shared with this workspace'),
          ] else
            _LockedCard(compact: !wide),
        ];

        return ListView(
          padding: pad,
          children: children.isNotEmpty
              ? children
              : [
                  _emptyMessage(
                    NodeDiscoveryService.instance.isRunning
                        ? 'No Erebrus AI nodes found on this network'
                        : 'Network discovery is stopped',
                  ),
                ],
        );
      },
    );
  }

  Widget _emptyMessage(String text) => Padding(
    padding: const EdgeInsets.only(top: 32),
    child: Center(
      child: Text(
        text,
        style: AppText.grotesk(13, color: AppColors.textSecondary),
      ),
    ),
  );
}

class _AddConnectionHint extends StatelessWidget {
  const _AddConnectionHint({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.stroke),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          const Icon(Symbols.cloud, size: 20, color: AppColors.accentHi),
          const SizedBox(width: 11),
          Expanded(
            child: Text(
              'Connect llama.cpp, Ollama, LM Studio, another Erebrus node by address, or a cloud provider to use and manage their models here.',
              style: AppText.grotesk(
                12.5,
                color: AppColors.textSecondary,
                height: 1.4,
              ),
            ),
          ),
          const SizedBox(width: 10),
          GhostButton('ADD', icon: Symbols.add, onTap: onTap),
        ],
      ),
    );
  }
}

class _DiscoveryErrorCard extends StatelessWidget {
  const _DiscoveryErrorCard({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.warn.withA(0.07),
        border: Border.all(color: AppColors.warn.withA(0.3)),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          const Icon(Symbols.wifi_off, size: 20, color: AppColors.warn),
          const SizedBox(width: 11),
          Expanded(
            child: Text(
              message,
              style: AppText.grotesk(
                12.5,
                color: AppColors.textSecondary,
                height: 1.4,
              ),
            ),
          ),
          const SizedBox(width: 10),
          GhostButton(
            'RESCAN',
            icon: Symbols.refresh,
            onTap: () async {
              await NodeDiscoveryService.instance.stop();
              await NodeDiscoveryService.instance.start();
            },
          ),
        ],
      ),
    );
  }
}

class _NodeCard extends StatelessWidget {
  const _NodeCard({required this.node, this.onOpenChat});

  final DiscoveredNode node;
  final VoidCallback? onOpenChat;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.stroke),
        borderRadius: BorderRadius.circular(16),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: AppColors.strokeSoft)),
            ),
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: AppColors.surface3,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    Symbols.device_hub,
                    size: 19,
                    color: AppColors.textSecondary,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              node.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: AppText.grotesk(
                                14.5,
                                weight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${node.host}:${node.port} · MDNS · ${node.error ?? (node.isLoadingModels ? 'LOADING MODELS' : 'ONLINE')}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.mono(10.5, color: AppColors.textMuted),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                const StatusBadge('ONLINE'),
              ],
            ),
          ),
          for (var i = 0; i < node.models.length; i++) ...[
            if (i > 0)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: Divider(height: 1, color: AppColors.strokeSoft),
              ),
            _NodeModelRow(
              node: node,
              model: node.models[i],
              onOpenChat: onOpenChat,
            ),
          ],
        ],
      ),
    );
  }
}

class _OrgModelsCard extends StatelessWidget {
  const _OrgModelsCard({required this.models, required this.wide});

  final List<SharedModel> models;
  final bool wide;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.orgPurple.withA(0.35)),
        borderRadius: BorderRadius.circular(16),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: AppColors.strokeSoft)),
            ),
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: AppColors.orgPurple.withA(0.14),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(
                    Symbols.apartment,
                    size: 19,
                    color: AppColors.orgPurple,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              app.selectedOrg?.name ?? 'Workspace',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: AppText.grotesk(
                                14.5,
                                weight: FontWeight.w600,
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                          const Icon(
                            Symbols.verified,
                            size: 15,
                            fill: 1,
                            color: AppColors.orgPurple,
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${models.length} shared model${models.length == 1 ? '' : 's'}',
                        style: AppText.mono(10.5, color: AppColors.textMuted),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.orgPurple.withA(0.14),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    'PRIVATE',
                    style: AppText.mono(
                      10,
                      weight: FontWeight.w600,
                      color: AppColors.orgPurple,
                      lsEm: 0.08,
                    ),
                  ),
                ),
              ],
            ),
          ),
          for (var i = 0; i < models.length; i++) ...[
            if (i > 0)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: Divider(height: 1, color: AppColors.strokeSoft),
              ),
            _OrgModelRow(model: models[i]),
          ],
        ],
      ),
    );
  }
}

class _OrgModelRow extends StatelessWidget {
  const _OrgModelRow({required this.model});

  final SharedModel model;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
      child: Row(
        children: [
          LetterTile(
            model.name.isNotEmpty ? model.name[0] : '?',
            size: 36,
            radius: 10,
            fontSize: 13,
            accent: true,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text.rich(
              TextSpan(
                text: model.name,
                style: AppText.grotesk(13.5, weight: FontWeight.w600),
                children: [
                  TextSpan(
                    text: (model.quant != null && model.quant!.isNotEmpty)
                        ? '  · ${model.quant} · ${model.size ?? ''}'
                        : (model.size != null && model.size!.isNotEmpty)
                        ? '  · ${model.size}'
                        : '',
                    style: AppText.mono(11, color: AppColors.textMuted),
                  ),
                ],
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 12),
          AccentChip('USE', onTap: () => app.selectModel(model.name, '')),
        ],
      ),
    );
  }
}

class _NodeModelRow extends StatelessWidget {
  const _NodeModelRow({
    required this.node,
    required this.model,
    this.onOpenChat,
  });

  final DiscoveredNode node;
  final DiscoveredNodeModel model;
  final VoidCallback? onOpenChat;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
      child: Row(
        children: [
          LetterTile(
            model.name.isEmpty ? '?' : model.name[0].toUpperCase(),
            accent:
                app.selectedNetworkNodeId == node.id &&
                app.selectedModelId == model.id,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text.rich(
              TextSpan(
                text: model.name,
                style: AppText.grotesk(13.5, weight: FontWeight.w600),
                children: [
                  TextSpan(
                    text: '  · ${model.spec.isEmpty ? model.id : model.spec}',
                    style: AppText.mono(11, color: AppColors.textMuted),
                  ),
                ],
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 12),
          AccentChip(
            app.selectedNetworkNodeId == node.id &&
                    app.selectedModelId == model.id
                ? 'USING'
                : 'USE',
            onTap: () {
              app.selectNetworkModel(node, model);
              if (onOpenChat != null) {
                onOpenChat!();
              } else {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('Using ${model.name} from ${node.name}'),
                  ),
                );
              }
            },
          ),
        ],
      ),
    );
  }
}

// ─── Guest gate ──────────────────────────────────────────────────────────────

class _LockedCard extends StatelessWidget {
  const _LockedCard({this.compact = false});

  final bool compact;

  @override
  Widget build(BuildContext context) {
    final border = Border.all(color: AppColors.accent.withA(0.35));
    final decoration = BoxDecoration(
      color: AppColors.accent.withA(0.05),
      border: border,
      borderRadius: BorderRadius.circular(16),
    );

    if (compact) {
      return DottedBorderBox(
        decoration: decoration,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 14),
          child: Row(
            children: [
              const Icon(Symbols.lock, size: 20, color: AppColors.accent),
              const SizedBox(width: 12),
              Expanded(
                child: AdaptiveRow(
                  leading: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Private workspace models',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.grotesk(13.5, weight: FontWeight.w600),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Sign in to see models your team shares.',
                        style: AppText.grotesk(
                          11.5,
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                  trailing: AccentChip(
                    'SIGN IN',
                    onTap: () => openSignIn(context),
                  ),
                  gap: 12,
                  stackedGap: 8,
                  minLeadingWidth: 180,
                  stackedAlignment: AlignmentDirectional.centerEnd,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return DottedBorderBox(
      decoration: decoration,
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: AppColors.accent.withA(0.12),
                borderRadius: BorderRadius.circular(13),
              ),
              child: const Icon(
                Symbols.lock,
                size: 22,
                color: AppColors.accent,
              ),
            ),
            const SizedBox(width: 18),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Private workspace models',
                    style: AppText.grotesk(15, weight: FontWeight.w600),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    'Teams share models on private org nodes. Sign in to see the '
                    'workspaces you belong to — everything else keeps working '
                    'without an account.',
                    style: AppText.grotesk(
                      12.5,
                      color: AppColors.textSecondary,
                      height: 1.45,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 18),
            PrimaryCta(
              'SIGN IN / REGISTER',
              fontSize: 12,
              radius: 11,
              glow: false,
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
              onTap: () => openSignIn(context),
            ),
          ],
        ),
      ),
    );
  }
}

/// Dashed-look border container. Flutter has no dashed Border out of the box;
/// the solid low-alpha accent border reads equivalently at 1px — the custom
/// painter below adds the dash pattern on top.
class DottedBorderBox extends StatelessWidget {
  const DottedBorderBox({
    super.key,
    required this.decoration,
    required this.child,
  });

  final BoxDecoration decoration;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      foregroundPainter: _DashedRRectPainter(
        color: AppColors.accent.withA(0.35),
        radius: 16,
      ),
      child: Container(
        decoration: BoxDecoration(
          color: decoration.color,
          borderRadius: decoration.borderRadius,
        ),
        child: child,
      ),
    );
  }
}

class _DashedRRectPainter extends CustomPainter {
  const _DashedRRectPainter({required this.color, required this.radius});

  final Color color;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = color;
    final path = Path()
      ..addRRect(
        RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(radius)),
      );
    for (final metric in path.computeMetrics()) {
      var d = 0.0;
      while (d < metric.length) {
        canvas.drawPath(metric.extractPath(d, d + 5), paint);
        d += 9;
      }
    }
  }

  @override
  bool shouldRepaint(_DashedRRectPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.radius != radius;
}

/// LOADED while the model is in memory, otherwise DOWNLOADED. Listens to
/// the inference service itself so only this badge rebuilds during chat.
class _MemoryBadge extends StatelessWidget {
  const _MemoryBadge({required this.modelId});

  final String modelId;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: InferenceService.instance,
    builder: (context, _) => InferenceService.instance.isLoaded(modelId)
        ? const StatusBadge('LOADED')
        : const StatusBadge(
            'DOWNLOADED',
            color: AppColors.textMuted,
            dot: false,
          ),
  );
}
