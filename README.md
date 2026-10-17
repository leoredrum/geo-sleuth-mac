# GeoSleuth for Mac

> **这只是一个 Mac App 外壳。** 所有定位能力都来自原项目 **[Oldcircle/geo-sleuth](https://github.com/Oldcircle/geo-sleuth)**（MIT License, © Oldcircle）。
> 本仓库只做了打包：图形界面、拖入 / 粘贴照片、调用本机 Claude Code 运行 geo-sleuth skill、把结果在 Google 地图中打开。
> 原项目的方法、脚本和案例请看原仓库，问题和贡献也请优先提给原项目。
>
> *This is only a macOS app wrapper. All geolocation work is done by the original project
> [Oldcircle/geo-sleuth](https://github.com/Oldcircle/geo-sleuth) (MIT, © Oldcircle).*

拖入、选择或 ⌘V 粘贴一张照片 → 定位 → 自动在 Google 地图打开。

## 工作方式

1. **照片自带 GPS（EXIF）**：直接读出坐标，立即打开 Google 地图，不需要 AI。
2. **没有 GPS**：点「开始 AI 定位」，App 在后台以无界面模式运行本机的 Claude Code（`claude -p`），
   加载内置的 [geo-sleuth](https://github.com/Oldcircle/geo-sleuth) skill 分析照片，最后输出坐标、误差半径、置信度和证据图，并自动打开 Google 地图。
   - 快速模式：约 5–15 分钟，只做元数据 / OCR / 反向图片搜索 + 视觉判断。
   - 深度模式：完整流程（地形天际线、卫星图、街景匹配），可能 30–90 分钟。

粘贴支持：Finder 里复制的图片文件（保留 EXIF）、截图、从浏览器 / 聊天软件复制的图片。

每次分析的工作目录在 `~/Library/Application Support/GeoSleuth/jobs/<时间>/`，里面有完整报告、`geo_result.json` 和证据图。

## 依赖

- macOS 14+，Xcode 命令行工具（Swift 5.9+）
- [Claude Code](https://code.claude.com) CLI，且**已登录**（`claude auth login`；App 检测到未登录时会提供「在终端中登录」按钮）
- [uv](https://docs.astral.sh/uv/)（geo-sleuth 的 Python 脚本用它运行）
- Google Chrome（反向图片搜索用，可选）

## 构建

```bash
git clone https://github.com/leoredrum/geo-sleuth-mac.git
cd geo-sleuth-mac
./build.sh
```

`build.sh` 会把原项目 clone 到 `../geo-sleuth`（已存在则直接使用，也可以用 `SKILL_SRC=/path/to/skills/geo-sleuth` 指定），
把 `skills/geo-sleuth` 和原项目的 LICENSE 一起打进 App，产物是 `build/GeoSleuth.app`。

```bash
cp -R build/GeoSleuth.app /Applications/
```

## 设置（⌘,）

- Claude Code 命令（默认 `claude`）
- 模型（留空用默认）
- 拿到坐标后是否自动打开 Google 地图

## 注意

- AI 模式下 Claude Code 被允许在工作目录里执行 shell 命令（运行 geo-sleuth 的脚本）。
- 照片会发送给 Claude，并可能上传到百度 / Yandex 做反向图片搜索。
- 请只用于你有权处理的照片，遵守原项目 SKILL.md 中的使用规则。

## 致谢 / Credits

- [Oldcircle/geo-sleuth](https://github.com/Oldcircle/geo-sleuth) — 定位方法、脚本与 skill 本体（MIT）。
- 本仓库的 App 外壳代码以 MIT 协议发布，见 [LICENSE](LICENSE)。
