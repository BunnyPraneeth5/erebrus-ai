import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../services/tools/web_tools.dart';
import '../../theme/app_colors.dart';
import '../../widgets/ere_controls.dart';
import '../../widgets/settings_kit.dart';

/// Settings → Tools: internet access for tool-capable models.
class ToolsSettingsContent extends StatefulWidget {
  const ToolsSettingsContent({super.key});

  @override
  State<ToolsSettingsContent> createState() => _ToolsSettingsContentState();
}

class _ToolsSettingsContentState extends State<ToolsSettingsContent> {
  final _searxng = TextEditingController();
  final _apiKey = TextEditingController();
  bool _showKey = false;
  bool _testing = false;
  String? _testResult;
  bool _testFailed = false;

  WebTools get _tools => WebTools.instance;

  @override
  void initState() {
    super.initState();
    _searxng.text = _tools.searxngUrl;
  }

  @override
  void dispose() {
    _searxng.dispose();
    _apiKey.dispose();
    super.dispose();
  }

  Future<void> _saveSearxng() async {
    FocusScope.of(context).unfocus();
    await _tools.setSearxngUrl(_searxng.text);
    _searxng.text = _tools.searxngUrl;
    _clearTest();
  }

  Future<void> _saveKey() async {
    final key = _apiKey.text.trim();
    if (key.isEmpty) return;
    FocusScope.of(context).unfocus();
    try {
      await _tools.setApiKey(_tools.provider, key);
      _apiKey.clear();
      _clearTest();
    } on Object catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not save the key: $error')));
    }
  }

  Future<void> _removeKey() async {
    await _tools.setApiKey(_tools.provider, '');
    _clearTest();
  }

  void _clearTest() => setState(() {
    _testResult = null;
    _testFailed = false;
  });

  Future<void> _test() async {
    setState(() {
      _testing = true;
      _testResult = null;
    });
    try {
      final results = await _tools.search('Erebrus AI local LLM', count: 3);
      _testFailed = false;
      _testResult = results.isEmpty
          ? '${_tools.provider.label} answered but returned no results.'
          : '${_tools.provider.label} works · first result: ${results.first.title}';
    } on WebToolException catch (error) {
      _testFailed = true;
      _testResult = error.message;
    } on Object catch (error) {
      _testFailed = true;
      _testResult = error.toString();
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _tools,
      builder: (context, _) {
        final provider = _tools.provider;
        final problem = _tools.configurationProblem;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SettingsGroup(
              title: 'Internet access',
              description:
                  'Let tool-capable models search the web and read pages, then '
                  'answer with numbered sources. Works with Connection models '
                  '(llama.cpp, Ollama, LM Studio, vLLM, OpenAI, Anthropic, '
                  'OpenRouter); switch it on per chat with the globe button.',
              children: [
                SettingItem(
                  title: 'Web search',
                  description: !_tools.enabled
                      ? 'Off · models cannot reach the internet'
                      : problem ?? 'On · ready to use in chats',
                  control: EreToggle(
                    value: _tools.enabled,
                    onChanged: _tools.setEnabled,
                  ),
                ),
                SettingItem(
                  title: 'Search provider',
                  description: provider.description,
                  control: EreSelect<SearchProvider>(
                    value: provider,
                    onChanged: (value) {
                      _tools.setProvider(value);
                      _apiKey.clear();
                      _clearTest();
                    },
                    options: [
                      for (final option in SearchProvider.values)
                        SelectOption(
                          option,
                          option.label,
                          description: option.requiresKey
                              ? (_tools.hasKey(option)
                                    ? 'API key saved'
                                    : 'Needs an API key')
                              : 'No API key',
                        ),
                    ],
                  ),
                ),
              ],
            ),
            SettingsFormCard(
              children: [
                if (provider == SearchProvider.searxng)
                  SettingsFormRow(
                    title: 'SearXNG URL',
                    description:
                        'Your instance’s address. JSON output must be enabled '
                        '(search.formats: [html, json] in settings.yml).',
                    field: Row(
                      children: [
                        Expanded(
                          child: EreTextField(
                            controller: _searxng,
                            hint: 'https://search.example.com',
                            mono: true,
                            keyboardType: TextInputType.url,
                          ),
                        ),
                        const SizedBox(width: 8),
                        PillButton('Save', onTap: _saveSearxng),
                      ],
                    ),
                  )
                else
                  SettingsFormRow(
                    title: '${provider.label} API key',
                    description: _tools.hasKey(provider)
                        ? 'Saved in the system keychain. Enter a new key to replace it.'
                        : 'Stored in the system keychain on this device only.',
                    field: Row(
                      children: [
                        Expanded(
                          child: EreTextField(
                            controller: _apiKey,
                            obscure: !_showKey,
                            mono: true,
                            hint: _tools.hasKey(provider)
                                ? '••••••••  saved'
                                : provider == SearchProvider.tavily
                                ? 'tvly-…'
                                : 'Subscription token',
                            suffix: IconButton(
                              tooltip: _showKey ? 'Hide key' : 'Show key',
                              icon: Icon(
                                _showKey
                                    ? Symbols.visibility_off
                                    : Symbols.visibility,
                                size: 18,
                                color: AppColors.textMuted,
                              ),
                              onPressed: () =>
                                  setState(() => _showKey = !_showKey),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        PillButton('Save', onTap: _saveKey),
                      ],
                    ),
                    fieldNote: _tools.hasKey(provider)
                        ? Align(
                            alignment: Alignment.centerRight,
                            child: PillButton(
                              'Remove key',
                              compact: true,
                              tone: PillTone.subtle,
                              onTap: _removeKey,
                            ),
                          )
                        : null,
                  ),
                SettingsFormRow(
                  title: 'Results per search',
                  field: EreSelect<int>(
                    value: _tools.maxResults,
                    width: double.infinity,
                    onChanged: _tools.setMaxResults,
                    options: [
                      for (final count in const [3, 5, 8, 10])
                        SelectOption(count, '$count results'),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 14, 18, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Align(
                        alignment: Alignment.centerRight,
                        child: PillButton(
                          'Test search',
                          icon: Symbols.travel_explore,
                          busy: _testing,
                          onTap: problem == null ? _test : null,
                        ),
                      ),
                      if (problem != null || _testResult != null) ...[
                        const SizedBox(height: 10),
                        SettingsNote(
                          _testResult ?? problem!,
                          tone: _testResult == null
                              ? NoteTone.warn
                              : _testFailed
                              ? NoteTone.danger
                              : NoteTone.success,
                          icon: _testResult != null && !_testFailed
                              ? Symbols.check_circle
                              : Symbols.info,
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 26),
            SettingsGroup(
              title: 'Reading pages',
              children: [
                SettingItem(
                  title: 'Open web pages',
                  description:
                      'Let models read a result in full. Only public sites: '
                      'this device and your local network are always blocked.',
                  control: EreToggle(
                    value: _tools.allowFetch,
                    onChanged: _tools.setAllowFetch,
                  ),
                ),
              ],
            ),
            SettingsNote(
              provider == SearchProvider.searxng
                  ? 'Search queries go to your SearXNG server. Pages are downloaded by this device. Tool results are treated as untrusted content.'
                  : 'Search queries go to ${provider.label}, a third-party service billed to your key. Pages are downloaded by this device. Tool results are treated as untrusted content.',
              icon: Symbols.shield,
            ),
          ],
        );
      },
    );
  }
}
