import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';

/// 自建雷达服务器的三步教程。
///
/// 只在用户主动点进来时出现：App 不内置任何服务器地址，也不替用户选后端。
/// 命令用等宽字体并允许选中复制——教程的价值在于能照着敲。
class RadarSelfHostPage extends StatelessWidget {
  const RadarSelfHostPage({super.key});

  static Route<void> route() =>
      MaterialPageRoute<void>(builder: (_) => const RadarSelfHostPage());

  @override
  Widget build(BuildContext context) {
    final t = context.l10n;
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Scaffold(
      appBar: AppBar(title: Text(t.radarSelfHostTitle)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
        children: [
          Text(
            t.radarSelfHostIntro,
            style: theme.textTheme.bodyMedium?.copyWith(
              height: 1.6,
              color: muted,
            ),
          ),
          const SizedBox(height: 20),
          _Step(title: t.radarSelfHostStep1, body: t.radarSelfHostStep1Body),
          _Step(title: t.radarSelfHostStep2, body: t.radarSelfHostStep2Body),
          _Step(title: t.radarSelfHostStep3, body: t.radarSelfHostStep3Body),
          const SizedBox(height: 8),
          Text(
            t.radarSelfHostDocs,
            style: theme.textTheme.bodySmall?.copyWith(color: muted),
          ),
        ],
      ),
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({required this.title, required this.body});

  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest.withValues(
                alpha: 0.5,
              ),
              borderRadius: BorderRadius.circular(10),
            ),
            child: SelectableText(
              body,
              style: theme.textTheme.bodySmall?.copyWith(
                height: 1.65,
                fontFamily: 'monospace',
                fontFamilyFallback: const ['Menlo', 'Consolas'],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
