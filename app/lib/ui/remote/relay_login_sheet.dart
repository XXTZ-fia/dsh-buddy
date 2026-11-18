import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/hosts_state.dart';
import '../../state/personal_server.dart';
import '../providers/provider_widgets.dart' show FormFieldBlock, FormFieldGroup;
import '../settings/settings_widgets.dart' show SettingsMetrics;
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';

/// Advanced: sign in to a self-hosted DSH Remote server (ds-harness-remote
/// `apps/server`) with email + password. The hosted server keeps using the
/// browser sign-in.
///
/// 这是一个整页，不再是底部弹层：真机（Android 16，targetSdk 28）上
/// `showAppSheet` 里的 TextField 点下去既不显示光标也不弹输入法——widget 测试
/// 里焦点和 `TextInput.show` 都正常，事件也能到达同一个弹层的按钮，只有输入框
/// 拿不到输入法；同一个 App 的整页表单（添加 SSH 主机）完全正常。
Future<void> showSelfHostedLogin(BuildContext context) =>
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const SelfHostedLoginSheet()));

/// 保留原名：调用点与测试都按这个类型找。
class SelfHostedLoginSheet extends ConsumerStatefulWidget {
  const SelfHostedLoginSheet({super.key});

  @override
  ConsumerState<SelfHostedLoginSheet> createState() => _SelfHostedLoginSheetState();
}

class _SelfHostedLoginSheetState extends ConsumerState<SelfHostedLoginSheet> {
  late final _server = TextEditingController(text: ref.read(relayServerProvider) ?? '');
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  String? _error;

  bool get _ownServer {
    final origin = normalizeRadarOrigin(_server.text);
    return origin == personalServerOrigin || origin == relayServerOrigin;
  }

  @override
  void dispose() {
    _server.dispose();
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    if (_busy) return;
    FocusManager.instance.primaryFocus?.unfocus();
    if (_server.text.trim().isEmpty || _email.text.trim().isEmpty || _password.text.isEmpty) {
      setState(() => _error = context.l10n.remoteRelayLoginRequired);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref
          .read(relayServerProvider.notifier)
          .loginWithPassword(server: _server.text, email: _email.text, password: _password.text);
      if (mounted) Navigator.of(context).pop();
    } on HostLinkError catch (e) {
      if (mounted) {
        setState(() => _error = _ownServer ? '${e.message}\n${context.l10n.remotePersonalRelayMissing}' : e.message);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _error = _ownServer ? context.l10n.remotePersonalRelayMissing : context.l10n.remoteErrSignIn);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    final navigator = Navigator.of(context);
    return AppPage.list(
      title: l10n.remoteSelfHostedServer,
      subtitle: Text(l10n.remoteSelfHostedSignInHelp),
      actions: [
        GlassIconButton(
          icon: AppIcons.close,
          tooltip: l10n.commonClose,
          onPressed: () => navigator.maybePop(),
        ),
      ],
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(SettingsMetrics.inset, 0, SettingsMetrics.inset, 4),
          child: Text(
            l10n.remotePersonalServerNotice,
            style: theme.textTheme.bodySmall?.copyWith(color: colors.textTertiary, height: 1.5),
          ),
        ),
        FormFieldGroup(
          children: [
            FormFieldBlock(
              label: l10n.remoteServerAddress,
              child: TextField(
                controller: _server,
                keyboardType: TextInputType.url,
                autocorrect: false,
                textInputAction: TextInputAction.next,
                style: AppType.mono(size: 14, color: theme.colorScheme.onSurface, height: 1.4),
                decoration: const InputDecoration(hintText: 'https://remote.example.com'),
              ),
            ),
            FormFieldBlock(
              label: l10n.remoteEmail,
              child: TextField(
                controller: _email,
                keyboardType: TextInputType.emailAddress,
                autocorrect: false,
                textInputAction: TextInputAction.next,
                autofillHints: const [AutofillHints.email],
                decoration: const InputDecoration(),
              ),
            ),
            FormFieldBlock(
              label: l10n.remotePassword,
              child: TextField(
                controller: _password,
                obscureText: true,
                obscuringCharacter: '•',
                // visiblePassword 让中文输入法切到 ASCII 键盘，否则标点会被
                // 打成全角、字母被拼音候选拦下来，密码根本没法输对。
                keyboardType: TextInputType.visiblePassword,
                autocorrect: false,
                enableSuggestions: false,
                autofillHints: const [AutofillHints.password],
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _login(),
                decoration: const InputDecoration(),
              ),
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(SettingsMetrics.inset, 20, SettingsMetrics.inset, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_error case final e?) ...[
                Text(e, style: theme.textTheme.bodySmall?.copyWith(color: colors.danger, height: 1.5)),
                const SizedBox(height: 12),
              ],
              FilledButton(
                onPressed: _busy ? null : _login,
                child: _busy
                    ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : Text(l10n.commonSignIn),
              ),
              const SizedBox(height: 4),
              TextButton(
                onPressed: _busy
                    ? null
                    : () async {
                        await ref.read(relayServerProvider.notifier).useDefault();
                        navigator.maybePop();
                      },
                child: Text(l10n.remoteUseOfficialRelay),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
