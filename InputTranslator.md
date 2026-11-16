Claude Code 中文悬浮输入助手 — 开发设计文档

项目名称： Claude Input Translator
版本： v1.0（MVP）
平台： macOS 15.0+
开发语言： Swift
技术框架： SwiftUI + AppKit + Apple Translation
项目类型： macOS 菜单栏常驻应用

⸻

1. 项目背景

Claude Code 主要通过终端交互。用户希望使用中文描述编程需求，但让 Claude Code 实际接收英文提示词。

开发一个 macOS 原生悬浮输入工具，实现：

中文输入 → 本地英文翻译 → 自动粘贴到 Claude Code 终端 → 原生执行。

本工具用本地翻译处理提示词和 Claude Code 回复。Claude Code 和 Codex CLI 的 Stop hook，以及 Gemini CLI 的 AfterAgent hook，提供最新完成的回复。按快捷键可从当前本机终端会话取出并显示中文。

项目目标是改善输入体验，不承诺降低账号封禁风险。

2. 核心功能

2.1 全局快捷键

快捷键	功能
⌘ + ⌥ + Space	显示或隐藏悬浮输入框
⌘ + Enter	翻译并粘贴到终端
Esc	关闭悬浮输入框
⌘ + A	全选输入内容
⌘ + ⌥ + ⇧ + Space	读取当前终端助手会话最新完成的回复
⌘ + ⇧ + V	在窗口内导入剪贴板并阅读回复

快捷键需要支持自定义，避免与其他应用冲突。

2.2 悬浮输入框

* 使用 AppKit NSPanel 实现。
* 使用 SwiftUI 构建输入界面。
* 支持多行中文输入。
* 支持中文输入法。
* 支持粘贴代码片段和 Markdown。
* 默认出现在屏幕中央。
* 支持窗口拖动。
* 支持自动聚焦输入框。
* 发送成功后自动隐藏。
* 翻译失败时保留原文。

2.3 本地翻译

使用 Apple Translation 框架：

* 默认翻译方向为 macOS 首选语言到英语。系统语言为英语时直接使用原文。
* 读回复使用写提示词语言对的反向。支持查看和复制译文，⌘ + Enter 复制译文。
* 界面语言默认跟随 macOS，手动选择后会在重开时保留。界面语言和翻译方向分别保存。
* 优先使用设备本地语言模型。
* 不依赖收费翻译 API。
* 首次使用时允许系统下载语言资源。
* 不将提示词上传到第三方翻译服务。
* 翻译失败时不自动发送中文。

技术要求：

使用 TranslationSession 执行翻译。由于 Translation 框架具有 SwiftUI 生命周期和语言资源管理要求，推荐通过 .translationTask 建立翻译会话，再由翻译服务协调调用。

翻译模型不可用、用户拒绝语言资源下载或系统不支持时，应显示明确错误。

2.4 自动发送

发送流程：

1. 用户在 Terminal 或 iTerm2 中使用 Claude Code。
2. 按全局快捷键打开悬浮输入框。
3. 程序记录此前激活的终端应用。
4. 用户输入中文。
5. 用户按 ⌘ + Enter。
6. 程序调用 Apple Translation。
7. 翻译成功后获取英文。
8. 激活此前记录的终端。
9. 确认终端获得焦点。
10. 将英文粘贴到终端。
11. 启用自动提交后，单行译文会在粘贴后自动按 Enter。多行译文由用户手动提交。
12. 隐藏悬浮输入框。

应用使用辅助功能 API 核对唤起时的终端进程、窗口与输入区域。多行译文粘贴前需确认终端助手能接收多行输入。

2.5 菜单栏

菜单栏显示一个翻译图标。

菜单包含：

* 写提示词
* 读当前助手回复
* 终端助手接入
* 翻译剪贴板
* 自动发送开关
* 终端选择
* 快捷键设置
* 开机启动
* 关于
* 退出

不在 Dock 中常驻显示应用图标。

⸻

3. 系统架构

ClaudeInputTranslator
│
├── App
│   ├── ClaudeInputTranslatorApp.swift
│   └── AppDelegate.swift
│
├── UI
│   ├── FloatingPanel.swift
│   ├── InputView.swift
│   ├── SettingsView.swift
│   └── MenuBarView.swift
│
├── Services
│   ├── TranslationService.swift
│   ├── HotkeyManager.swift
│   ├── TerminalManager.swift
│   ├── PasteService.swift
│   └── PermissionManager.swift
│
├── Models
│   ├── AppSettings.swift
│   └── TranslationState.swift
│
└── Utilities
    └── Logger.swift

模块职责：

TranslationService

负责中英双向翻译、翻译任务状态管理、语言资源异常处理和超时提示。

HotkeyManager

注册全局快捷键，检测冲突并响应唤起操作。优先采用系统支持的全局热键机制，不依赖持续监听用户所有键盘输入。

TerminalManager

记录前台终端应用、识别 Terminal 和 iTerm2、恢复目标应用焦点。

PasteService

负责剪贴板写入、模拟粘贴、可选发送以及必要的剪贴板恢复。

PermissionManager

负责检测辅助功能授权，并引导用户前往 macOS 系统设置授权。

⸻

4. 翻译策略

4.1 默认翻译模式

保留用户原始技术含义，不主动增加、删除或改变任务要求。

示例：

中文：

帮我检查当前项目中所有 SQL，找出可能存在全表扫描的地方。

英文：

Check all SQL queries in the current project and identify potential full table scans.

4.2 技术文本保护

尽可能保持以下内容不变：

* 文件路径，例如 /src/main.py
* 变量名，例如 user_id
* 函数名，例如 getUserInfo()
* SQL 表名和字段名
* Shell 命令
* Markdown 代码块
* JSON Key
* URL

建议 MVP 先实现代码块和行内代码的占位符保护。

处理步骤：

1. 识别 Markdown 代码块和行内代码。
2. 将代码内容替换为唯一占位符。
3. 翻译普通自然语言。
4. 还原占位符。
5. 校验占位符数量及内容。
6. 校验失败时取消自动发送。

输入停顿约 450 毫秒后自动更新预览。中文输入法组字期间等待文字上屏。预览完成后可复制英文或粘贴译文。

⸻

5. 终端交互设计

5.1 支持终端

MVP 优先支持：

* macOS Terminal.app
* iTerm2

后续可扩展：

* Ghostty
* Warp
* WezTerm
* Alacritty

5.2 输入方式

优先使用剪贴板粘贴，而不是逐字符模拟键盘输入。

原因：

* 处理长文本更快。
* 避免英文特殊字符输入错误。
* 支持多行提示词。
* 减少键盘布局差异造成的问题。

5.3 安全策略

默认关闭自动 Enter，首次运行时让用户明确选择是否启用。

对于多行文本，应验证目标终端和 Claude Code 的粘贴行为，避免多行内容被当作多个独立命令执行。

如目标终端无法识别、焦点恢复失败或辅助功能权限不足：

* 不执行粘贴。
* 不发送 Enter。
* 保留翻译结果。
* 提供复制英文按钮。

剪贴板恢复仅在能够确认剪贴板未被其他应用修改时执行，避免覆盖用户新复制的内容。

⸻

6. UI 设计

6.1 悬浮窗口

使用 macOS 原生窗口标题栏和关闭按钮。写提示词默认为 570 × 320 pt，阅读回复默认为 620 × 420 pt。两种视图可分别调整窗口大小。

写提示词时，光标直接进入中文输入框，英文预览显示在下方。顶部显示目标终端，底部提供粘贴按钮。Claude Code 回复完成后，按 ⌘ + ⌥ + ⇧ + Space 直接打开当前会话的中文译文；需要时可展开英文原文。

设置分为「通用」「终端」「助手接入」「快捷键」，可从菜单栏或通过 ⌘ + , 打开。窗口支持 ⌘ + W 关闭。

6.2 状态显示

支持以下状态：

* 等待输入
* 正在翻译
* 翻译成功
* 正在发送
* 发送成功
* 翻译失败
* 终端不可用
* 权限不足

翻译进行中可以继续编辑。按 ⌘↵ 可等待当前译文后粘贴。继续修改原文会取消待粘贴操作，预览会随最新原文更新。

⸻

7. 数据与隐私

7.1 数据处理原则

* 不记录用户输入的完整提示词。
* 不上传翻译历史。
* Stop hook 只在本机临时目录缓存会话最新的一条完成回复，SessionEnd 时清除。
* 通过终端的自动化接口获取当前标签页或分屏的 TTY，按前台进程组和启动时间配对。
* 默认关闭调试日志中的文本内容。
* 本地设置使用 UserDefaults。

7.2 系统权限

可能涉及：

辅助功能权限

用于激活终端后的自动化粘贴和按键操作。

自动化权限

如果使用 Apple Events 控制 Terminal 或 iTerm2，则需要对应授权。

输入监控权限

不作为默认要求。优先选择不需要监听全部键盘事件的全局快捷键实现。

所有权限都必须按实际使用的系统 API 申请，不能要求用户无条件开启全部权限。

⸻

8. 配置设计

使用 UserDefaults 保存以下配置：

配置项	默认值
sourceLanguage	zh-Hans
targetLanguage	en
globalHotkey	⌘⌥Space
autoSubmit	false
targetTerminal	lastActive
launchAtLogin	false
clearInputAfterSuccess	true
preserveClipboard	true

⸻

9. 技术要求

9.1 开发环境

* macOS 15.0+
* Xcode（使用支持目标 SDK 的版本）
* 使用可打开现有工程格式并支持 macOS Translation SDK 的 Xcode 工具链
* SwiftUI
* AppKit
* Translation
* ApplicationServices
* ServiceManagement（开机启动）

9.2 并发要求

* 翻译使用 Swift Concurrency。
* 不阻塞主线程。
* UI 状态在 MainActor 更新。
* 取消翻译时不得继续发送。
* 防止快捷键重复触发。
* 终端操作采用明确的状态机。

9.3 性能目标

* 悬浮窗口唤起：目标小于 200 ms。
* 已安装语言资源时，短文本翻译目标小于 2 秒。
* 终端粘贴：目标小于 500 ms。
* 空闲状态尽可能降低 CPU 和内存占用。

以上为设计目标，不是 Apple Translation 的性能保证，需在真实设备上测试。

⸻

10. 开发阶段

第一阶段：基础应用

* [ ]	创建 macOS SwiftUI 项目
* [ ]	实现菜单栏常驻
* [ ]	实现 NSPanel 悬浮窗口
* [ ]	实现中文输入框
* [ ]	实现全局快捷键
* [ ]	实现窗口显示与隐藏

验收标准：可在任意应用前台通过快捷键打开悬浮输入框。

第二阶段：翻译能力

* [ ]	集成 Apple Translation
* [ ]	支持中文到英文
* [ ]	实现语言资源下载引导
* [ ]	实现翻译状态管理
* [ ]	实现翻译错误处理
* [ ]	实现英文结果预览

验收标准：断网且语言资源已安装时，能够完成中文到英文翻译。

第三阶段：终端交互

* [ ]	识别当前终端
* [ ]	记录终端窗口
* [ ]	实现辅助功能权限检查
* [ ]	实现焦点恢复
* [ ]	实现英文粘贴
* [ ]	实现可选自动 Enter
* [ ]	实现失败保护

验收标准：在 Terminal 和 iTerm2 中能稳定将英文粘贴到 Claude Code 输入位置。

第四阶段：完善体验

* [ ]	添加设置界面
* [ ]	支持开机启动
* [ ]	支持快捷键自定义
* [ ]	支持代码块保护
* [ ]	支持翻译预览
* [ ]	实现基础日志
* [ ]	测试多显示器与全屏模式
* [ ]	打包 macOS .app

验收标准：无需手动启动开发环境，即可正常使用应用。

⸻

11. 测试计划

功能测试

1. 中文短文本翻译。
2. 长文本翻译。
3. 中英文混合翻译。
4. SQL 和代码块保护。
5. 中文输入法组合输入。
6. 全局快捷键冲突。
7. Terminal 输入与粘贴。
8. iTerm2 输入与粘贴。
9. 自动发送开关。
10. 终端关闭后的错误处理。

异常测试

1. 未授权辅助功能。
2. 目标终端已关闭。
3. 目标终端不在 Claude Code 输入状态。
4. 翻译语言模型未下载。
5. 翻译过程被取消。
6. 用户快速连续提交。
7. 翻译结果为空。
8. 翻译过程中切换终端。
9. 多行文本意外触发 Shell 命令。
10. 剪贴板在发送过程中被其他应用修改。

兼容性测试

至少覆盖 macOS 15 和一个更新的 macOS 版本，并分别测试 Terminal.app 和 iTerm2。

⸻

12. 非功能范围

MVP 暂不实现：

* Claude Code API 代理
* 实时翻译仍在生成的 Claude Code 输出
* 自动读取 Claude Code 对话历史
* 云端账号系统
* 翻译历史云同步
* AI 提示词自动优化
* Windows / Linux 版本
* 规避账号风控或服务限制的功能

⸻

13. 最终交付要求

开发完成后交付：

1. 完整 Xcode 工程。
2. 可编译运行的 Swift 源码。
3. 可本地运行的 macOS .app。
4. README 安装使用说明。
5. 权限配置说明。
6. 已知问题列表。
7. 基础单元测试和终端交互测试说明。

最终验收场景：

用户在 macOS 的 Terminal 或 iTerm2 中运行 Claude Code。

按 ⌘ + ⌥ + Space 打开悬浮输入框，输入中文需求，按 ⌘ + Enter 完成翻译并粘贴。

自动按 Enter 默认关闭。启用后，确认目标终端可以接收输入时才会自动提交单行译文。多行译文由用户手动提交。

Claude Code 接收到英文内容，正常执行，输出完全保持原样。

整个过程不需要修改 Claude Code 本身。
