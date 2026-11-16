# InputTranslator

[English](README.md)

InputTranslator 是 macOS 15 或更新版本上的菜单栏工具。它用 Apple Translation 在设备上翻译选定的语言对，再把译文粘贴回 Terminal 或 iTerm2 中的终端助手。接入 Claude Code、Codex CLI 或 Gemini CLI 后，也可以直接读取当前会话最新完成的回复并反向翻译。翻译浮窗在 macOS 26 及以上使用原生 Liquid Glass 控件，macOS 15 使用标准按钮。

## 安装与使用

1. 下载 macOS 通用 ZIP，解压后把 `InputTranslator.app` 拖入「应用程序」并打开。从菜单栏选择「写提示词」或进入设置。发布页也会说明当前下载的签名状态及首次打开步骤。[GitHub Releases](https://github.com/akz142857/InputTranslator/releases/latest)
2. 在系统设置的「隐私与安全性 → 辅助功能」中为这一份 `InputTranslator.app` 授权。部分 macOS 版本将此列表显示为「设备控制与数据访问（Device Control and Data Access）」。只使用翻译和复制时可以跳过授权。
3. 将焦点放在 Terminal 或 iTerm2 的 Claude Code 输入区，按 `⌘⌥Space` 直接打开提示词输入框。快捷键冲突时可在设置中录制新组合。
4. 在「设置 → 语言」中可分别选择界面语言、原文语言和译文语言。界面默认跟随 macOS 首选语言，手动选过的界面语言会在重开后保留。写提示词的默认方向是 macOS 首选语言 → 英语，读回复使用反向语言对。系统语言为英语时会直接使用原文。可翻译的语言由 macOS 提供，首次使用某个语言对时，系统可能要求下载对应资源。输入停顿约半秒后，输入区下方会显示译文预览，使用输入法时会等候选文字上屏再翻译。
5. 按一次 `⌘↵` 或点「粘贴到终端」即可粘贴单行译文。翻译尚在进行时，按 `⌘↵` 会等待当前译文。多行粘贴可再按一次 `⌘↵` 确认。也可点「复制译文」，用 `Esc` 返回或关闭窗口，用 `⌘A` 全选原文。

「设置 → 终端 → 粘贴后自动按 Enter」默认关闭。开启后，单行内容只需点一次「粘贴并提交」或按一次 `⌘↵`，即可粘贴并按 Enter。多行译文要求确认粘贴，提交时请手动按 Enter。未置顶时，粘贴完成会收起浮窗，顶部入口会短暂显示「已粘贴」。点右上角图钉或菜单栏的「置顶浮窗」，可让浮窗在切换应用和粘贴完成后继续显示。重启会恢复置顶浮窗的位置和大小，焦点仍留在原应用。原显示器断开时，浮窗会移到可用的屏幕。权限或焦点检查失败时，原文和已生成的译文会留在窗口中。

## 顶部停靠

顶部停靠默认开启。屏幕顶部的「翻译」入口有刘海时对齐摄像头区域，无刘海时对齐屏幕中央。点击胶囊会把它展开成翻译窗。点窗口右上角的上箭头可缩回胶囊。按住胶囊可拖到屏幕其他位置，重开会保留落点。右键点胶囊并选择「恢复默认」可移回屏幕顶部。可在「设置 → 通用」或菜单栏关闭「顶部停靠」。

拖动面板顶部的把手可将它移出，拖回「翻译」入口附近可重新停靠。面板右侧也有移出和重新停靠按钮。重新停靠会对齐胶囊当前位置，优先放在下方，下方放不下时放在上方。图钉独立控制置顶。App 会记住停靠状态，以及移出后的位置和大小。开启置顶时，重开 App 会直接恢复浮窗。

## 接入终端助手

打开菜单栏的「终端助手接入…」或设置中的「助手接入」标签。选择要用的助手并点击「连接」。应用会检测配置状态。应用移动或回调不完整时，点击「修复」；点击「断开」可移除 InputTranslator 添加的回调。

| 助手 | 回复完成事件 | 用户配置 |
| --- | --- | --- |
| Claude Code | `Stop` | `~/.claude/settings.json` |
| Codex CLI | `Stop` | `~/.codex/hooks.json` |
| Gemini CLI | `AfterAgent` | `~/.gemini/settings.json` |

Codex CLI 的 hook 新增或修复后，在 Codex 里输入 `/hooks`，确认信任 InputTranslator 的回调。其他已有配置会保留。使用自定义配置目录时，从带相应环境变量的终端启动 App。

在 Terminal 或 iTerm2 中打开本机助手会话，从浮窗切到「读回复」，或在终端按 `⌘⌥⇧Space`。首次读取时，允许 macOS 对该终端的「自动化」访问。「读回复」浮窗可见时，助手每完成一轮就会自动读取并翻译当前会话的新回复。置顶后可以边操作终端边查看更新。「从剪贴板读取」和手动输入的内容由你控制。App 会反向使用当前语言对。例如写提示词选日语 → 英语时，读回复就是英语 → 日语。

切换「写提示词」和「读回复」时，窗口保持原来的位置和大小。阅读区顶部会显示来源和当前显示的语言，可就地切换「译文」和「原文」。按 `⌘R` 读取最新回复，按 `⌘↵` 复制译文，或按 `Esc` 返回原应用。读取失败会保留已显示的回复。

App 通过 macOS 自动化读取当前标签页或分屏的终端设备（TTY），再用前台进程组匹配本机会话的回复。每个会话仅缓存最新完成的一条回复，保存在当前用户的私有临时目录，会话结束时清除。Hook 事件输入上限为 4 MiB，回复缓存上限为 16 MiB。通过 SSH 或 tmux 运行的助手可使用剪贴板导入回复。

## 构建

用 Xcode 打开 `InputTranslator/InputTranslator.xcodeproj`，选择 InputTranslator scheme。本地构建可以使用临时签名。

```sh
xcodebuild -project InputTranslator/InputTranslator.xcodeproj \
  -scheme InputTranslator -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath DerivedData \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO ONLY_ACTIVE_ARCH=NO build

mkdir -p dist
ditto DerivedData/Build/Products/Release/InputTranslator.app dist/InputTranslator.app
```

项目关闭 App Sandbox，以便在用户授权后核对其他进程的可访问性焦点和发送粘贴按键。自动粘贴需要辅助功能权限。按终端会话读取回复需要自动化权限。设置保存在 UserDefaults，翻译草稿保留在内存中。

## 测试

```sh
xcodebuild -project InputTranslator/InputTranslator.xcodeproj \
  -scheme InputTranslator -destination 'platform=macOS' \
  -parallel-testing-enabled NO -only-testing:InputTranslatorTests \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO test
```

在 macOS 15 和更新版本上分别检查 Terminal 与 iTerm2：

- 在 Claude Code 等待输入时，用中文输入法输入「检查 `user_id` 在哪里使用」。按一次 `⌘↵`，应在原输入区看到英文，原会话应仍在等待手动提交。
- 在自动预览里检查代码块和行内代码，预览时原终端输入应保持原样。关闭辅助功能权限后再次测试，确认译文仍可复制。
- 测试另一个标签页或分屏、终端查找框、翻译期间切换应用、取消翻译，以及剪贴板在粘贴期间被其他应用修改的情况。确认应用只向原输入区域粘贴，且保留新剪贴板内容。
- 测试多行输入及单行自动提交。开启自动提交时，只按一次 `⌘↵` 就应粘贴并提交单行译文。多行译文应完整显示在 Claude Code 输入区，等待手动提交。
- 首次下载语言资源后断网测试；同时检查全屏、外接显示器、快捷键冲突和开机启动。

## 已知限制

- 辅助功能能核对终端窗口和输入焦点，无法识别终端里当前运行的程序或确认按键已被 Claude Code 接收。启用自动按 Enter 前，请用实际会话验证粘贴交接。
- 多行粘贴的行为受终端和会话配置影响。若终端进入自己的粘贴确认模式，请检查原终端。译文可通过预览复制后手动粘贴。
- 开启保留剪贴板时，自动粘贴最多备份 64 MiB 的剪贴板数据。超出时，请用「复制译文」手动粘贴。
- 当前精确保留 Markdown 围栏代码块和反引号行内代码。请用行内代码标记需要保持原样的路径、变量名或命令。系统翻译若改动占位符，应用会改为分段翻译代码周围的正文，句子衔接可能有所变化。
- 移动或替换 App 后，macOS 可能要求重新授予辅助功能权限。
- 如果权限列表开关已打开，应用仍提示缺少辅助功能权限，请退出应用，移除权限列表中的旧条目，从「应用程序」重新添加当前版本，再启动应用。自行构建时，请选择实际运行的那一份 App。

## 参与贡献

提交问题或代码改动请参考[贡献指南](CONTRIBUTING.md)。发现安全问题时，请参考[安全报告说明](SECURITY.md)。

## 许可证

InputTranslator 采用 [MIT 许可证](LICENSE)。
