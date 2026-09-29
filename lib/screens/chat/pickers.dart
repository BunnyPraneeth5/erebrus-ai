import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../data/catalog_entry.dart';
import '../../data/catalog_service.dart';
import '../../data/model_connection.dart';
import '../../services/connection_service.dart';
import '../../services/imported_model_service.dart';
import '../../services/inference_service.dart';
import '../../services/model_download_service.dart';
import '../../services/model_package_service.dart';
import '../../services/node_discovery_service.dart';
import '../../services/persona_service.dart';
import '../../state/app_state.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_text.dart';
import '../../widgets/ere_controls.dart';

/// Model / persona pickers for the chat header chips.
/// Desktop: centered dialog. Mobile: bottom sheet.

void showModelPicker(BuildContext context) {
  final app = AppScope.of(context);
  final byId = {for (final entry in CatalogService.entries) entry.id: entry};
  final local = ModelDownloadService.instance.completed
      .map((id) => byId[id])
      .whereType<CatalogEntry>()
      .toList();
  final packaged = ModelPackageService.instance.installed
      .where((model) => model.runnable)
      .map((model) => (model: model, catalog: byId[model.modelId]))
      .where((item) => item.catalog != null)
      .toList();
  final imported = ImportedModelService.instance.models;
  final nodes = NodeDiscoveryService.instance.nodes;
  _showPicker(
    context,
    title: 'SWITCH MODEL',
    children: [
      _PickerGroupLabel('ON THIS DEVICE'),
      if (local.isEmpty && packaged.isEmpty && imported.isEmpty)
        _PickerEmpty('No downloaded models')
      else
        for (final model in local)
          _PickerRow(
            leading: LetterTile(
              model.letter,
              accent:
                  !app.isNetworkModelSelected &&
                  model.id == app.selectedModelId,
            ),
            title: model.name,
            meta: model.spec,
            trailing: _memoryBadge(model.id),
            selected:
                !app.isNetworkModelSelected && model.id == app.selectedModelId,
            onTap: () {
              app.selectModel(model.name, model.quant, id: model.id);
              Navigator.of(context).pop();
            },
          ),
      for (final item in packaged)
        if (!local.any((model) => model.id == item.model.modelId))
          _PickerRow(
            leading: LetterTile(
              item.catalog!.letter,
              accent:
                  !app.isNetworkModelSelected &&
                  item.model.modelId == app.selectedModelId,
            ),
            title: item.catalog!.name,
            meta:
                '${item.model.format.toUpperCase()} · ${item.model.backends.join(' / ')}',
            trailing: _memoryBadge(item.model.modelId),
            selected:
                !app.isNetworkModelSelected &&
                item.model.modelId == app.selectedModelId,
            onTap: () {
              app.selectModel(
                item.catalog!.name,
                item.model.format.toUpperCase(),
                id: item.model.modelId,
                variantId: item.model.variantId,
              );
              Navigator.of(context).pop();
            },
          ),
      for (final model in imported)
        _PickerRow(
          leading: LetterTile(
            model.name.isEmpty ? '?' : model.name[0].toUpperCase(),
            accent:
                !app.isNetworkModelSelected && model.id == app.selectedModelId,
          ),
          title: model.name,
          meta: [
            if (model.parameterLabel.isNotEmpty) model.parameterLabel,
            model.format.toUpperCase(),
            model.backend,
          ].join(' · '),
          trailing: InferenceService.instance.isLoaded(model.id)
              ? _memoryBadge(model.id)
              : const StatusBadge('IMPORTED', dot: true),
          selected:
              !app.isNetworkModelSelected && model.id == app.selectedModelId,
          onTap: () {
            app.selectModel(
              model.name,
              model.quantization.isEmpty
                  ? model.format.toUpperCase()
                  : model.quantization,
              id: model.id,
              variantId: model.variantId,
            );
            Navigator.of(context).pop();
          },
        ),
      for (final node in nodes) ...[
        _PickerGroupLabel(node.name.toUpperCase()),
        if (node.models.isEmpty)
          _PickerEmpty(
            node.isLoadingModels ? 'Loading models…' : 'No models advertised',
          ),
        for (final model in node.models)
          _PickerRow(
            leading: LetterTile(
              model.name.isEmpty ? '?' : model.name[0].toUpperCase(),
              accent:
                  app.selectedNetworkNodeId == node.id &&
                  app.selectedModelId == model.id,
            ),
            title: model.name,
            meta: [
              if (model.spec.isNotEmpty) model.spec,
              '${node.host}:${node.port}',
            ].join(' · '),
            trailing: const Icon(
              Symbols.wifi,
              size: 15,
              color: AppColors.success,
            ),
            selected:
                app.selectedNetworkNodeId == node.id &&
                app.selectedModelId == model.id,
            onTap: () {
              app.selectNetworkModel(node, model);
              Navigator.of(context).pop();
            },
          ),
      ],
      for (final connection in ConnectionService.instance.enabledConnections)
        if (connection.modelIds.isNotEmpty) ...[
          _PickerGroupLabel(connection.name.toUpperCase()),
          for (final model in ConnectionService.instance.modelsFor(connection))
            _PickerRow(
              leading: LetterTile(
                model.id.isEmpty ? '?' : model.id[0].toUpperCase(),
                accent:
                    app.selectedNetworkNodeId == connection.nodeId &&
                    app.selectedModelId == model.id,
              ),
              title: model.id,
              meta: [
                connection.provider.label,
                connection.hostLabel,
              ].join(' · '),
              trailing: model.state == RemoteModelState.loaded
                  ? const StatusBadge('LOADED', dot: true)
                  : Icon(
                      connection.provider.isLocal ? Symbols.lan : Symbols.cloud,
                      size: 15,
                      color:
                          ConnectionService.instance.errorFor(connection.id) ==
                              null
                          ? AppColors.success
                          : AppColors.danger,
                    ),
              selected:
                  app.selectedNetworkNodeId == connection.nodeId &&
                  app.selectedModelId == model.id,
              onTap: () {
                app.selectConnectionModel(connection, model.id);
                Navigator.of(context).pop();
              },
            ),
        ],
    ],
  );
}

/// LOADED only for the model actually in memory; other downloaded models
/// are READY to load.
Widget _memoryBadge(String modelId) =>
    InferenceService.instance.isLoaded(modelId)
    ? const StatusBadge('LOADED', dot: true)
    : const StatusBadge('READY', color: AppColors.textMuted, dot: false);

void showPersonaPicker(BuildContext context) {
  final app = AppScope.of(context);
  final service = PersonaService.instance;
  _showPicker(
    context,
    title: 'SWITCH PERSONA',
    children: [
      _PickerGroupLabel('BUILT-IN'),
      for (final p in service.builtIns)
        _PickerRow(
          leading: LetterTile(
            p.initials,
            size: 28,
            radius: 9,
            fontSize: 11,
            accent: p.effectiveId == app.selectedPersonaId,
          ),
          title: p.name,
          meta: p.meta,
          selected: p.effectiveId == app.selectedPersonaId,
          onTap: () {
            app.selectPersona(p.name, id: p.effectiveId);
            Navigator.of(context).pop();
          },
        ),
      _PickerGroupLabel('YOURS'),
      if (service.userPersonas.isEmpty)
        _PickerEmpty('No saved personas')
      else
        for (final p in service.userPersonas)
          _PickerRow(
            leading: LetterTile(p.initials, size: 28, radius: 9, fontSize: 11),
            title: p.name,
            meta: p.meta,
            selected: p.effectiveId == app.selectedPersonaId,
            onTap: () {
              app.selectPersona(p.name, id: p.effectiveId);
              Navigator.of(context).pop();
            },
          ),
    ],
  );
}

class _PickerEmpty extends StatelessWidget {
  const _PickerEmpty(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
    child: Text(text, style: AppText.grotesk(12, color: AppColors.textMuted)),
  );
}

void _showPicker(
  BuildContext context, {
  required String title,
  required List<Widget> children,
}) {
  final wide = MediaQuery.sizeOf(context).width >= 900;
  final content = _PickerContent(title: title, children: children);
  if (wide) {
    showDialog<void>(
      context: context,
      barrierColor: Colors.black.withA(0.6),
      builder: (_) => Dialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: const BorderSide(color: AppColors.strokeHi),
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400, maxHeight: 560),
          child: content,
        ),
      ),
    );
  } else {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      barrierColor: Colors.black.withA(0.6),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
      ),
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.72,
      ),
      builder: (_) => content,
    );
  }
}

class _PickerContent extends StatelessWidget {
  const _PickerContent({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 18, 14, 18),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Text(title, style: AppText.sectionHeader()),
          ),
          const SizedBox(height: 8),
          Flexible(child: ListView(shrinkWrap: true, children: children)),
        ],
      ),
    );
  }
}

class _PickerGroupLabel extends StatelessWidget {
  const _PickerGroupLabel(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 14, 6, 7),
      child: Text(
        label,
        style: AppText.mono(
          10,
          weight: FontWeight.w500,
          color: AppColors.textFaint,
          lsEm: 0.12,
        ),
      ),
    );
  }
}

class _PickerRow extends StatelessWidget {
  const _PickerRow({
    required this.leading,
    required this.title,
    required this.meta,
    this.trailing,
    this.selected = false,
    this.onTap,
  });

  final Widget leading;
  final String title;
  final String meta;
  final Widget? trailing;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
        decoration: BoxDecoration(
          color: selected ? AppColors.surface3 : null,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            leading,
            const SizedBox(width: 11),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: AppText.grotesk(
                      13,
                      weight: selected ? FontWeight.w600 : FontWeight.w500,
                      color: selected
                          ? AppColors.textPrimary
                          : AppColors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    meta,
                    style: AppText.mono(
                      9.5,
                      color: selected
                          ? AppColors.textTertiary
                          : AppColors.textFaint,
                    ),
                  ),
                ],
              ),
            ),
            ?trailing,
          ],
        ),
      ),
    );
  }
}
