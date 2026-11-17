import 'package:flutter/foundation.dart';

/// 个人首页的目的地。用枚举而不是裸下标：信息雷达是可选的，关闭时第 1 项不是雷达，
/// 任何「跳到第 N 个 tab」的旧写法都会跳错页。
enum PersonalTab { work, radar, automation, library, settings }

/// Lets any page switch the personal-home tabs without importing the shell
/// (which would create an import cycle with the settings screen).
/// A null value means "no pending request".
final personalTabRequest = ValueNotifier<PersonalTab?>(null);

void openPersonalTab(PersonalTab tab) => personalTabRequest.value = tab;

/// Set by PersonalHome while its tabs are mounted. Avoids reading the
/// protected ChangeNotifier.hasListeners from outside the notifier.
bool personalTabsAvailable = false;
