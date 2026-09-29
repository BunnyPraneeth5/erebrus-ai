import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../auth/runtime_config.dart';
import '../../auth/wallet_auth_controller.dart';
import '../../platform/platform_capabilities.dart';
import '../../state/app_state.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_text.dart';
import '../../widgets/spark_logo.dart';

void openSignIn(BuildContext context) {
  Navigator.of(
    context,
    rootNavigator: true,
  ).push(MaterialPageRoute<void>(builder: (_) => const SignInPage()));
}

class SignInPage extends StatefulWidget {
  const SignInPage({super.key});

  @override
  State<SignInPage> createState() => _SignInPageState();
}

class _SignInPageState extends State<SignInPage> {
  WalletAuthController? _auth;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final auth = AppScope.of(context).auth;
    if (identical(_auth, auth)) return;
    _auth?.removeListener(_onAuthChanged);
    _auth = auth..addListener(_onAuthChanged);
    if (PlatformCapabilities.usesReown) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (mounted) await auth.initReown(context);
      });
    }
  }

  @override
  void dispose() {
    _auth?.removeListener(_onAuthChanged);
    super.dispose();
  }

  bool _closing = false;

  void _onAuthChanged() {
    if (_closing || _auth?.isAuthenticated != true || !mounted) return;
    // Sign-in notifies many times (session, entitlement, profile, …). Close
    // exactly once, after the current frame, and only while this page is
    // still on the stack — popping again would remove the home route.
    _closing = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final route = ModalRoute.of(context);
      if (route == null || !route.isActive) return;
      Navigator.of(context).popUntil((candidate) => candidate.isFirst);
    });
  }

  @override
  Widget build(BuildContext context) {
    final auth = _auth!;
    return AnimatedBuilder(
      animation: auth,
      builder: (context, _) => Scaffold(
        body: Container(
          decoration: const BoxDecoration(gradient: AppColors.warmRadial),
          child: SafeArea(
            child: Stack(
              children: [
                _body(auth),
                if (auth.isAuthenticating || auth.awaitingWebCallback)
                  _LoadingOverlay(auth: auth),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _body(WalletAuthController auth) {
    final desktop = PlatformCapabilities.isDesktop;
    final solanaMobile = auth.isSolanaMobileDevice;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 36),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Symbols.arrow_back, size: 17),
                  label: Text(
                    'CONTINUE AS GUEST',
                    style: AppText.mono(
                      11,
                      weight: FontWeight.w500,
                      color: AppColors.textSecondary,
                      lsEm: 0.08,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 24),
              const Center(child: LogoTile(size: 56, radius: 16, glow: true)),
              const SizedBox(height: 18),
              Text(
                'Welcome to Erebrus AI',
                textAlign: TextAlign.center,
                style: AppText.grotesk(
                  26,
                  weight: FontWeight.w600,
                  lsEm: -0.02,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Sign in or register to access private workspace models and share yours with your team.',
                textAlign: TextAlign.center,
                style: AppText.grotesk(
                  14,
                  color: AppColors.textTertiary,
                  height: 1.45,
                ),
              ),
              const SizedBox(height: 28),
              if (desktop) ...[
                if (auth.appleLoginAvailable) ...[
                  _AuthButton(
                    label: 'Continue with Apple',
                    icon: Symbols.ios,
                    onTap: auth.signInWithApple,
                  ),
                  const SizedBox(height: 11),
                ],
                _AuthButton(
                  label: 'Sign in with browser',
                  icon: Symbols.open_in_browser,
                  primary: true,
                  onTap: auth.openWebSignIn,
                ),
                const SizedBox(height: 14),
                Text(
                  'Opens ${RuntimeConfig.erebrusWebOrigin}/auth in your browser.\nAfter sign-in, you’ll return here automatically.',
                  textAlign: TextAlign.center,
                  style: AppText.grotesk(
                    11.5,
                    color: AppColors.textFaint,
                    height: 1.45,
                  ),
                ),
              ] else if (solanaMobile) ...[
                _AuthButton(
                  label: 'Connect Solana Wallet',
                  icon: Symbols.account_balance_wallet,
                  primary: true,
                  onTap: auth.signInWithSolanaMobile,
                ),
                const SizedBox(height: 14),
                Text(
                  'Your Seed Vault wallet signs you in — no password required.',
                  textAlign: TextAlign.center,
                  style: AppText.grotesk(11.5, color: AppColors.textFaint),
                ),
              ] else ...[
                if (auth.emailLoginAvailable) ...[
                  _AuthButton(
                    label: 'Continue with Email',
                    icon: Symbols.mail,
                    onTap: () => _showEmailSheet(auth),
                  ),
                  const SizedBox(height: 11),
                ],
                if (auth.googleLoginAvailable || auth.appleLoginAvailable) ...[
                  _SocialLoginButtons(
                    googleAvailable: auth.googleLoginAvailable,
                    appleAvailable: auth.appleLoginAvailable,
                    onGooglePressed: auth.signInWithGoogle,
                    onApplePressed: auth.signInWithApple,
                  ),
                  const SizedBox(height: 11),
                ],
                const _DividerLabel(label: 'CONNECT A WALLET'),
                _WalletCard(
                  enabled: auth.reownReady,
                  label: auth.reownReady
                      ? 'Connect Wallet'
                      : 'Preparing Wallet…',
                  onTap: auth.openWalletModal,
                ),
                if (!auth.reownReady &&
                    !auth.emailLoginAvailable &&
                    !auth.googleLoginAvailable &&
                    !auth.appleLoginAvailable) ...[
                  const SizedBox(height: 11),
                  _AuthButton(
                    label: 'Sign in with browser',
                    icon: Symbols.open_in_browser,
                    onTap: auth.openWebSignIn,
                  ),
                ],
              ],
              if (auth.authError case final error? when error.isNotEmpty) ...[
                const SizedBox(height: 18),
                Text(
                  error,
                  textAlign: TextAlign.center,
                  style: AppText.grotesk(
                    12,
                    color: AppColors.danger,
                    height: 1.4,
                  ),
                ),
              ],
              const SizedBox(height: 24),
              Text(
                'By continuing you agree to Erebrus’s Terms of Service & Privacy Policy.',
                textAlign: TextAlign.center,
                style: AppText.grotesk(
                  11.5,
                  color: AppColors.textFaint,
                  height: 1.5,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showEmailSheet(WalletAuthController auth) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => _EmailLoginSheet(auth: auth),
    );
  }
}

class _AuthButton extends StatelessWidget {
  const _AuthButton({
    required this.label,
    required this.onTap,
    required this.icon,
    this.primary = false,
  });

  final String label;
  final FutureOr<void> Function() onTap;
  final IconData icon;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: primary ? AppColors.accent : AppColors.surface2,
      shape: RoundedRectangleBorder(
        side: BorderSide(
          color: primary ? AppColors.accent : AppColors.strokeHi,
        ),
        borderRadius: BorderRadius.circular(14),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => onTap(),
        child: SizedBox(
          height: 52,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 19,
                color: primary ? AppColors.onAccent : AppColors.accent,
              ),
              const SizedBox(width: 11),
              Text(
                label,
                style: AppText.grotesk(
                  15,
                  weight: FontWeight.w600,
                  color: primary ? AppColors.onAccent : AppColors.textPrimary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Matches Erebrus Drop: when both native providers are available they share
/// one segmented row; a single available provider still fills the full width.
class _SocialLoginButtons extends StatelessWidget {
  const _SocialLoginButtons({
    required this.googleAvailable,
    required this.appleAvailable,
    required this.onGooglePressed,
    required this.onApplePressed,
  });

  final bool googleAvailable;
  final bool appleAvailable;
  final FutureOr<void> Function() onGooglePressed;
  final FutureOr<void> Function() onApplePressed;

  @override
  Widget build(BuildContext context) {
    final bothAvailable = googleAvailable && appleAvailable;
    return Material(
      color: AppColors.surface2,
      shape: RoundedRectangleBorder(
        side: const BorderSide(color: AppColors.strokeHi),
        borderRadius: BorderRadius.circular(14),
      ),
      clipBehavior: Clip.antiAlias,
      child: Row(
        children: [
          if (googleAvailable)
            Expanded(
              child: _SocialLoginSegment(
                semanticLabel: 'Continue with Google',
                label: bothAvailable ? 'Google' : 'Continue with Google',
                monoGlyph: 'G',
                onTap: onGooglePressed,
              ),
            ),
          if (bothAvailable)
            Container(width: 1, height: 28, color: AppColors.strokeHi),
          if (appleAvailable)
            Expanded(
              child: _SocialLoginSegment(
                semanticLabel: 'Continue with Apple',
                label: bothAvailable ? 'Apple' : 'Continue with Apple',
                icon: Icons.apple,
                onTap: onApplePressed,
              ),
            ),
        ],
      ),
    );
  }
}

class _SocialLoginSegment extends StatelessWidget {
  const _SocialLoginSegment({
    required this.semanticLabel,
    required this.label,
    required this.onTap,
    this.icon,
    this.monoGlyph,
  });

  final String semanticLabel;
  final String label;
  final FutureOr<void> Function() onTap;
  final IconData? icon;
  final String? monoGlyph;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: semanticLabel,
      excludeSemantics: true,
      child: InkWell(
        onTap: () => onTap(),
        child: SizedBox(
          height: 52,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (icon != null)
                Icon(icon, size: 21, color: AppColors.textPrimary)
              else
                Text(
                  monoGlyph ?? '',
                  style: AppText.mono(17, weight: FontWeight.w600, height: 1),
                ),
              const SizedBox(width: 9),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.grotesk(14, weight: FontWeight.w600),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DividerLabel extends StatelessWidget {
  const _DividerLabel({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 15),
    child: Row(
      children: [
        const Expanded(child: Divider(color: AppColors.stroke)),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Text(
            label,
            style: AppText.mono(10.5, color: AppColors.textFaint, lsEm: 0.14),
          ),
        ),
        const Expanded(child: Divider(color: AppColors.stroke)),
      ],
    ),
  );
}

class _WalletCard extends StatelessWidget {
  const _WalletCard({
    required this.enabled,
    required this.label,
    required this.onTap,
  });

  final bool enabled;
  final String label;
  final Future<void> Function() onTap;

  @override
  Widget build(BuildContext context) => Opacity(
    opacity: enabled ? 1 : 0.55,
    child: Material(
      color: AppColors.accent.withA(0.07),
      shape: RoundedRectangleBorder(
        side: BorderSide(color: AppColors.accent.withA(0.45)),
        borderRadius: BorderRadius.circular(14),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: enabled ? onTap : null,
        child: SizedBox(
          height: 58,
          child: Row(
            children: [
              const SizedBox(width: 15),
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [AppColors.solanaA, AppColors.solanaB],
                  ),
                  borderRadius: BorderRadius.circular(9),
                ),
              ),
              const SizedBox(width: 13),
              Expanded(
                child: Text(
                  label,
                  style: AppText.grotesk(15, weight: FontWeight.w600),
                ),
              ),
              Text(
                'SOLANA',
                style: AppText.mono(10, color: AppColors.accent, lsEm: 0.08),
              ),
              const SizedBox(width: 15),
            ],
          ),
        ),
      ),
    ),
  );
}

class _EmailLoginSheet extends StatefulWidget {
  const _EmailLoginSheet({required this.auth});
  final WalletAuthController auth;

  @override
  State<_EmailLoginSheet> createState() => _EmailLoginSheetState();
}

class _EmailLoginSheetState extends State<_EmailLoginSheet> {
  final _email = TextEditingController();
  final _code = TextEditingController();
  bool _sent = false;
  bool _busy = false;

  @override
  void dispose() {
    _email.dispose();
    _code.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.auth,
    builder: (context, _) => Padding(
      padding: EdgeInsets.fromLTRB(
        24,
        22,
        24,
        MediaQuery.viewInsetsOf(context).bottom + 28,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            _sent ? 'Enter your code' : 'Sign in with email',
            style: AppText.grotesk(20, weight: FontWeight.w600),
          ),
          const SizedBox(height: 7),
          Text(
            _sent
                ? 'We sent a code to ${_email.text.trim()}.'
                : 'We’ll email you a one-time sign-in code.',
            style: AppText.grotesk(13, color: AppColors.textTertiary),
          ),
          const SizedBox(height: 18),
          TextField(
            controller: _sent ? _code : _email,
            autofocus: true,
            keyboardType: _sent
                ? TextInputType.number
                : TextInputType.emailAddress,
            decoration: InputDecoration(
              hintText: _sent ? '6-digit code' : 'you@example.com',
              filled: true,
              fillColor: AppColors.surface2,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
          const SizedBox(height: 14),
          FilledButton(
            onPressed: _busy ? null : (_sent ? _verify : _send),
            style: FilledButton.styleFrom(minimumSize: const Size(0, 50)),
            child: _busy
                ? const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(_sent ? 'Verify' : 'Send code'),
          ),
          if (_sent)
            TextButton(
              onPressed: _busy ? null : () => setState(() => _sent = false),
              child: const Text('Use a different email'),
            ),
          if (widget.auth.authError case final error?
              when error.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              error,
              textAlign: TextAlign.center,
              style: AppText.grotesk(12, color: AppColors.danger),
            ),
          ],
        ],
      ),
    ),
  );

  Future<void> _send() async {
    if (_email.text.trim().isEmpty) return;
    setState(() => _busy = true);
    final sent = await widget.auth.requestEmailLoginCode(_email.text);
    if (mounted) {
      setState(() {
        _busy = false;
        _sent = sent;
      });
    }
  }

  Future<void> _verify() async {
    setState(() => _busy = true);
    await widget.auth.verifyEmailLoginCode(
      email: _email.text,
      code: _code.text,
    );
    if (!mounted) return;
    setState(() => _busy = false);
    // On success the sign-in page closes itself and this sheet with it.
  }
}

class _LoadingOverlay extends StatefulWidget {
  const _LoadingOverlay({required this.auth});
  final WalletAuthController auth;

  @override
  State<_LoadingOverlay> createState() => _LoadingOverlayState();
}

class _LoadingOverlayState extends State<_LoadingOverlay> {
  Timer? _timer;
  bool _showCancel = false;

  @override
  void initState() {
    super.initState();
    _timer = Timer(const Duration(seconds: 8), () {
      if (mounted) setState(() => _showCancel = true);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Positioned.fill(
    child: ColoredBox(
      color: AppColors.bg.withA(0.88),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(color: AppColors.accent),
            const SizedBox(height: 16),
            Text(
              widget.auth.awaitingWebCallback
                  ? 'Waiting for browser sign-in'
                  : 'Signing in…',
              style: AppText.grotesk(14, color: AppColors.textSecondary),
            ),
            if (widget.auth.awaitingWebCallback) ...[
              const SizedBox(height: 7),
              Text(
                'Complete sign-in in your browser. You’ll return here automatically.',
                textAlign: TextAlign.center,
                style: AppText.grotesk(12, color: AppColors.textTertiary),
              ),
              const SizedBox(height: 22),
              Text(
                'Browser didn’t return?',
                style: AppText.grotesk(12.5, color: AppColors.textFaint),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: widget.auth.signInFromClipboard,
                icon: const Icon(Symbols.content_paste_go, size: 18),
                label: const Text('Paste token from clipboard'),
              ),
            ],
            if (_showCancel) ...[
              const SizedBox(height: 12),
              TextButton(
                onPressed: widget.auth.cancelAuthentication,
                child: const Text('Cancel'),
              ),
            ],
          ],
        ),
      ),
    ),
  );
}
