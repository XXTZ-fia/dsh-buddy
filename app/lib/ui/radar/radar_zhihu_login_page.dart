import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../l10n/l10n.dart';
import 'radar_hot_api.dart';

/// 在手机里登录知乎，登完把 Cookie 交给服务端。
///
/// 知乎对机房 IP 要求登录态，服务端自己拿不到验证码；让用户在熟悉的手机
/// WebView 里扫码/短信登录，再把 `z_c0` 这些 Cookie 存到自己的服务器上。
class RadarZhihuLoginPage extends StatefulWidget {
  const RadarZhihuLoginPage({super.key, required this.api});

  final RadarHotApi api;

  @override
  State<RadarZhihuLoginPage> createState() => _RadarZhihuLoginPageState();
}

class _RadarZhihuLoginPageState extends State<RadarZhihuLoginPage> {
  late final WebViewController _web = WebViewController()
    ..setJavaScriptMode(JavaScriptMode.unrestricted)
    ..setBackgroundColor(const Color(0xFFF6F6F6))
    ..setNavigationDelegate(
      NavigationDelegate(
        onNavigationRequest: (request) {
          // 只允许知乎自己的页面；外链交回系统浏览器会丢掉登录态。
          final host = Uri.tryParse(request.url)?.host ?? '';
          return host.endsWith('zhihu.com') ? NavigationDecision.navigate : NavigationDecision.prevent;
        },
        onPageFinished: (url) => _maybeCapture(url),
      ),
    )
    ..loadRequest(Uri.parse('https://www.zhihu.com/signin?next=%2F'));

  bool _busy = false;
  bool _saved = false;

  Future<void> _maybeCapture(String url) async {
    if (_busy || _saved) return;
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.host.endsWith('zhihu.com')) return;
    if (uri.path.contains('signin') || uri.path.contains('login')) return;
    setState(() => _busy = true);
    try {
      final cookies = await WebViewCookieManager().getCookies(domain: Uri.parse('https://www.zhihu.com'));
      final header = cookies.map((c) => '${c.name}=${c.value}').join('; ');
      if (!header.contains('z_c0=')) {
        if (mounted) setState(() => _busy = false);
        return;
      }
      await widget.api.saveZhihuCookie(header);
      if (!mounted) return;
      _saved = true;
      Navigator.of(context).pop(true);
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.radarZhihuCookieFailed('$error'))),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(context.l10n.radarZhihuLoginTitle),
        actions: [
          if (_busy)
            const Padding(
              padding: EdgeInsets.only(right: 16),
              child: Center(child: SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))),
            ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Row(
              children: [
                const Icon(Icons.info_outline, size: 18),
                const SizedBox(width: 8),
                Expanded(child: Text(context.l10n.radarZhihuLoginHint)),
              ],
            ),
          ),
          Expanded(child: WebViewWidget(controller: _web)),
        ],
      ),
    );
  }
}
