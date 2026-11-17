import 'package:dsh_app/state/mention_state.dart';
import 'package:dsh_app/ui/chat/mention/mention_controller.dart';
import 'package:dsh_app/ui/chat/mention/mention_picker.dart';
import 'package:dsh_app/ui/chat/mention/mention_syntax.dart';
import 'package:dsh_app/ui/chat/mention/mention_text_controller.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart' show loadTestFonts, testApp;

/// A host that has nothing to reference: experts and the phone's own files are
/// the only rows, which is exactly the disconnected case.
class _EmptySource implements MentionSource {
  @override
  Future<List<FileReferenceCandidate>> files(String sessionId, String query) async => const [];

  @override
  Future<List<SessionReferenceCandidate>> sessions(String sessionId, String query) async => const [];

  @override
  Future<List<SessionSummary>> allSessions() async => const [];
}

MentionItem _expert(String id, String name) =>
    MentionItem(key: 'a:$id', kind: MentionKind.expert, label: name, mention: '', detail: null);

class _Fixture {
  _Fixture() {
    picker = MentionPickerController(
      input: input,
      source: () => _EmptySource(),
      sessionId: () => 'main',
      localSessions: () async => const [],
      recents: MentionRecents(persist: false),
      expertItems: (query) async => [
        for (final (id, name) in const [('standard', '标准模式'), ('cordis', '创造模式')])
          if (fuzzyScore(name, query) != null) _expert(id, name),
      ],
      onPickExpert: (item) => expertsPicked.add(item.key),
      onPickDeviceFile: () async => deviceFilePicked = true,
    );
  }

  final input = MentionTextController();
  final expertsPicked = <String>[];
  bool deviceFilePicked = false;
  late final MentionPickerController picker;

  void type(String text) {
    // 一个字一个字地放进控制器：整段塞进去会被当成粘贴，`@lib/` 直接变成签，
    // 那正好是面板该关上的情况，不是这里要测的。
    for (var i = 1; i <= text.length; i++) {
      input.value = TextEditingValue(
        text: text.substring(0, i),
        selection: TextSelection.collapsed(offset: i),
      );
    }
  }

  void dispose() {
    picker.dispose();
    input.dispose();
  }
}

void main() {
  setUpAll(loadTestFonts);

  testWidgets('the panel shows the expert group above the phone file row', (tester) async {
    final f = _Fixture();
    addTearDown(f.dispose);
    f.type('@');
    await tester.pumpWidget(
      testApp(
        Material(
          child: ListenableBuilder(
            listenable: Listenable.merge([f.input, f.picker]),
            builder: (context, _) => MentionPicker(controller: f.picker),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 120));
    await tester.pump();

    // 分组标题与行都用 l10n 的同一套词：专家、以及末尾的本机文件入口。
    expect(find.text('专家'), findsOneWidget);
    expect(find.text('标准模式'), findsOneWidget);
    expect(find.text('创造模式'), findsOneWidget);
    expect(find.textContaining('从这台手机添加文件'), findsOneWidget);

    await tester.tap(find.text('创造模式'));
    await tester.pump();
    expect(f.expertsPicked, ['a:cordis']);
  });
  testWidgets('a bare @ lists the experts after the empty file group', (tester) async {
    final f = _Fixture();
    addTearDown(f.dispose);
    f.type('@');
    await tester.pump(const Duration(milliseconds: 120));
    await tester.pump();

    expect(f.picker.sections.map((s) => s.items.length), [2]);
    expect(f.picker.items.map((i) => i.kind), [MentionKind.expert, MentionKind.expert]);
    expect(f.picker.items.map((i) => i.mention), ['', '']);
  });

  testWidgets('picking an expert switches instead of writing @name', (tester) async {
    final f = _Fixture();
    addTearDown(f.dispose);
    f.type('@创造');
    await tester.pump(const Duration(milliseconds: 120));
    await tester.pump();

    expect(f.picker.items.single.label, '创造模式');
    f.picker.pick(f.picker.items.single);

    expect(f.expertsPicked, ['a:cordis']);
    expect(f.input.text, '');
    expect(f.input.tokens, isEmpty);
    expect(f.picker.isOpen, isFalse);
  });

  testWidgets('a typed sentence around the @ keeps the rest of the draft', (tester) async {
    final f = _Fixture();
    addTearDown(f.dispose);
    f.type('帮我看看 @标准');
    await tester.pump(const Duration(milliseconds: 120));
    await tester.pump();

    f.picker.pick(f.picker.items.single);

    expect(f.expertsPicked, ['a:standard']);
    expect(f.input.text, '帮我看看 ');
  });

  testWidgets('an expert pick is not remembered as a reference', (tester) async {
    final f = _Fixture();
    addTearDown(f.dispose);
    f.type('@标准');
    await tester.pump(const Duration(milliseconds: 120));
    await tester.pump();

    f.picker.pick(f.picker.items.single);

    expect(f.picker.recents.entries, isEmpty);
    expect(MentionLabels.all, isNot(contains('标准模式')));
  });

  testWidgets('the phone file row drops the @word before handing over', (tester) async {
    final f = _Fixture();
    addTearDown(f.dispose);
    f.type('@报告');
    await tester.pump(const Duration(milliseconds: 120));
    await tester.pump();

    await f.picker.pickDeviceFile();

    expect(f.deviceFilePicked, isTrue);
    expect(f.input.text, '');
    expect(f.picker.isOpen, isFalse);
  });

  testWidgets('a path query keeps the phone file row out of the way', (tester) async {
    final f = _Fixture();
    addTearDown(f.dispose);
    f.type('@lib/');
    await tester.pump(const Duration(milliseconds: 120));
    await tester.pump();

    expect(f.picker.query?.pathOnly, isTrue);
    await f.picker.pickDeviceFile();
    expect(f.deviceFilePicked, isFalse);
    expect(f.input.text, '@lib/');
  });
}
