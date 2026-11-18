import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 雷达里「问 AI」的跨页信使：雷达行写入提示词，个人页切回工作，聊天页填进输入框。
class RadarAskController extends Notifier<String?> {
  @override
  String? build() => null;

  void ask(String prompt) => state = prompt;

  String? take() {
    final value = state;
    state = null;
    return value;
  }
}

final radarAskProvider = NotifierProvider<RadarAskController, String?>(RadarAskController.new);

String radarAskPrompt({
  required String platform,
  required String title,
  required String url,
  String summary = '',
}) {
  final kind = platform.toLowerCase();
  final tail = summary.trim().isEmpty ? '' : '\n简介：${summary.trim()}';
  if (kind.contains('github')) {
    return '请分析这个 GitHub 项目，重点看：\n'
        '1. 它解决什么问题、核心能力；\n'
        '2. 维护活跃度、issue/PR 情况、许可证；\n'
        '3. 工程上是否值得跟进或引入，有什么风险。\n\n'
        '项目：$title\n链接：$url$tail';
  }
  if (kind.contains('arxiv') || kind.contains('paper') || kind.contains('hugging') || kind.contains('hf')) {
    return '请解读这篇论文，重点看：\n'
        '1. 研究问题与动机；\n'
        '2. 方法核心；\n'
        '3. 主要实验结论；\n'
        '4. 局限与可复现性。\n\n'
        '论文：$title\n链接：$url$tail';
  }
  return '请分析这条信息的真实性、原始信源和关键事实，重点看：\n'
      '1. 最早出处与是否有一手来源；\n'
      '2. 哪些平台/媒体在报道，是否互相印证；\n'
      '3. 可能的偏差、旧闻重发或标题党；\n'
      '4. 给出可信度判断和需要核对的点。\n\n'
      '标题：$title\n链接：$url$tail';
}
