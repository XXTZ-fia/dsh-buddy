# 品牌与吉祥物素材

DSH Go 的源码以 AGPL-3.0 发布（见 [LICENSE](LICENSE)），但下面这些品牌和美术素材**不在 AGPL-3.0 授权范围内**。它们的版权归 ccch1mneyyy（DSH-TUI）所有，保留所有权利。

你可以为了构建、测试和运行本仓库而使用它们。如果你以修改版或衍生作品的身份再发布，请换成自己的名称和素材。

| 素材 | 位置 | 来源 |
|---|---|---|
| 岸宝品牌图标 | `app/assets/brand/anbao.png`（App 内 BrandMark）、`app/assets/brand/anbao_mascot.png`（透明底吉祥物）、`app/android/app/src/main/res/mipmap-*/ic_launcher*.png`、求 Star 弹窗贴纸 `app/assets/star/star_anbao.webp` | 本项目自备的新吉祥物「岸宝」 |
| 岸宝像素桌宠 | `app/assets/pets/deepy-whale/`；生成脚本 `app/tool/make_pet_pack.py`、源文件 `app/tool/pet_src/deepy-whale/` | 沿用 [Clawd on Desk](https://github.com/rullerzhou-afk/clawd-on-desk) 主题包格式；帧图已全部换成岸宝静态形象，不再包含第三方美术素材 |
| 岸宝像素表情 | `app/assets/pets/whale-girl/`；源文件 `app/tool/pet_src/whale-girl/` | 同上，帧图已全部换成岸宝静态形象 |
| 岸宝插画桌宠 | `app/assets/pets/anbao/`；源文件 `app/tool/pet_src/anbao/`（16 个二值 alpha APNG + `theme.json`），打包同上 | 以 `anbao.png` 为原画的剪纸骨架动画：头/身两层、AI 表情变体只换脸部像素、道具程序化绘制 |

`app/lib/ui/shell/brand_glyph.g.dart`（旧鱼尾矢量）只保留给 `BrandMark` 的静态几何量，界面上不再绘制。`app/assets/whale/` 的精灵图也已换成岸宝，文件名沿用旧清单以避免改代码；DeepSeek 官方图标不再随 App 分发。

旧版第三方素材（DSH-TUI 的像素鲸鱼形象、鲸娘表情、DeepSeek 鲸鱼尾巴）的版权说明见 `THIRD_PARTY_NOTICES.md`；若以衍生作品再发布，请保留相应署名并注意其非商用限制。

go.dshtui.com 首页（`site/home/`）由社区开发者 ClayGao233 / 采云师烧饼制作，网页本身的来源和使用条件见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。其中的 `dist/assets/dsh-go.svg`（`app/assets/brand/tile.svg` 的副本）、`dist/assets/dsh-go-pop.svg`（由品牌图形改出的立体版）、`dist/assets/author/share.png`（`docs/assets/social-preview.png` 的副本）和功能展示图里的品牌图形、岸宝形象同样适用本页的条件。

仓库首页 README 用到的展示素材 `docs/assets/`（首图、社交预览图、桌宠动图、社群二维码）同样适用本页的条件：可以随本仓库一起查看和转载介绍，不要用在你自己发布的产品上。

宠物包由 `app/tool/make_pet_pack.py` 从 `app/tool/pet_src/` 生成，品牌图形的代码由 `app/tool/make_brand_mark.py` 从 `app/assets/brand/` 生成。工具脚本本身和其他源码一样，以 AGPL-3.0 发布。

伙伴小屋的 Live2D 素材不在这个仓库和 APK 里：Cubism Core（Live2D 专有许可）、Cubism Web Framework（Live2D Open Software License）和角色模型都打成单独的素材包，用时才放进手机，见 [docs/design/companion.md](docs/design/companion.md)。模型的作者和授权写在素材包的 `character.json` 里，App 菜单底部原样显示。

第三方的代码、字体、图标和运行时组件见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
