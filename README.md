# InputTranslator

[简体中文](README.zh-CN.md)

InputTranslator is a menu bar app for writing prompts and reading AI assistant replies in your preferred language. It uses Apple Translation to translate on your Mac. Paste translated prompts into Terminal or iTerm2, then read replies from Claude Code, Codex CLI, or Gemini CLI in the reverse language direction.

Requires **macOS 15 or later**. One universal build supports Apple silicon and Intel Macs. The floating panel uses native Liquid Glass controls on macOS 26 and later.

## Install and get started

1. Download the universal macOS ZIP, unzip it, and move `InputTranslator.app` to **Applications**. [GitHub Releases](https://github.com/akz142857/InputTranslator/releases/latest)
2. Open the app from Applications. Use its menu bar icon to open **Write Prompt** or **Settings**. The [release page](https://github.com/akz142857/InputTranslator/releases/latest) lists the signing status and any first-launch steps for the current download.
3. Open **Settings → Language** to choose the interface language and translation direction. The interface follows your macOS language by default and remembers a manual selection. Prompt translation defaults to your preferred system language → English. **Read Reply** reverses that pair. macOS may prompt you to install the translation languages on first use.

## macOS permissions

| Action | Setup |
| --- | --- |
| Paste into Terminal or iTerm2 | Enable InputTranslator in **System Settings → Privacy & Security → Accessibility**. This may appear as **Device Control and Data Access**. If the app is missing from the list, add the copy in **Applications**. Translation and copying work without this permission. |
| Read replies from the current terminal session | Connect your assistant in **Settings → Assistants**. On the first read, allow InputTranslator to control Terminal or iTerm2 in the macOS prompt. Check this under **System Settings → Privacy & Security → Automation**. |

## Write a prompt

With your terminal input focused, press **⌘⌥Space** to open the prompt panel. After you pause typing, the translated preview appears below the editor. If you use an input method, translation starts after you commit the composed text.

Press **⌘↵** or click **Paste to Terminal** to paste a single-line translation. If translation is running, the shortcut waits for the result. For multiple lines, press **⌘↵** again to confirm the paste. You can also copy the translation and paste it yourself.

**Automatically press Enter after pasting** is off by default. In **Settings → Terminal**, you can enable it for single-line prompts. Submit multiline prompts manually. If the app loses the terminal focus or permission, your draft and translation stay in the panel.

## Read an assistant reply

In **Settings → Assistants**, click **Connect** for your assistant. Use **Repair** if you move the app or the connection is incomplete. **Disconnect** removes the hooks added by InputTranslator.

| Assistant | Reply event | Default configuration |
| --- | --- | --- |
| Claude Code | `Stop` | `~/.claude/settings.json` |
| Codex CLI | `Stop` | `~/.codex/hooks.json` |
| Gemini CLI | `AfterAgent` | `~/.gemini/settings.json` |

After connecting or repairing Codex CLI, enter `/hooks` in Codex and trust the InputTranslator hooks. If your assistant uses a custom configuration directory, start InputTranslator from a terminal with the corresponding environment variables.

In a connected session, press **⌘⌥⇧Space** or select **Read Reply**. While the panel is visible, new completed replies are read and translated as they arrive. Switch between **Translation** and **Original** to read either version. **⌘R** reads the latest reply, **⌘↵** copies the translation, and **Esc** returns to the previous app. **Read Clipboard** or **⌘⇧V** translates a reply you copy manually.

To match a reply to a local session, macOS Automation reads the terminal device (TTY) of the selected tab or split pane, and the app checks its foreground process group. It keeps each session's latest completed reply in a private temporary directory and clears it when the session ends. Hook input is limited to 4 MiB, and the reply cache is limited to 16 MiB. For SSH or tmux sessions, use the clipboard to import replies.

## Dock and pin the panel

Top Dock is enabled by default. Click the Translate capsule to expand the panel. The capsule aligns with the camera notch on supported displays and with the center of the screen on other displays. Drag it to move it, or use **Restore Default** in its context menu.

Drag the panel's top handle to detach it. Drag it back near the capsule or use the dock button to reattach it. The window opens below the capsule when space allows and above it when space is limited. Pin the panel to keep it visible when you switch apps. InputTranslator remembers the window's position and size.

## Build from source

Open `InputTranslator/InputTranslator.xcodeproj` in Xcode and select the InputTranslator scheme. To build a local universal app with ad hoc signing, run the following commands.

```sh
xcodebuild -project InputTranslator/InputTranslator.xcodeproj \
  -scheme InputTranslator -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath DerivedData \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO ONLY_ACTIVE_ARCH=NO build

mkdir -p dist
ditto DerivedData/Build/Products/Release/InputTranslator.app dist/InputTranslator.app
```

InputTranslator uses macOS Accessibility to check the target window and send paste keystrokes. It uses Automation to identify the active terminal session. App Sandbox is disabled for these integrations. Settings are stored in UserDefaults, and translation drafts are kept in memory.

## Test

```sh
xcodebuild -project InputTranslator/InputTranslator.xcodeproj \
  -scheme InputTranslator -destination 'platform=macOS' \
  -parallel-testing-enabled NO -only-testing:InputTranslatorTests \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO test
```

Verify both Terminal and iTerm2 with a running assistant. Check live previews, preservation of inline code and fenced blocks, and single-line and multiline paste. Test default paste behavior and opt-in submission. Check how the app handles changes to the focused tab, split pane, app, and clipboard. Once the translation languages are installed, test offline translation as well.

## Troubleshooting and limits

- macOS Accessibility exposes the focused terminal window and input element. It cannot confirm that the assistant received the paste keystroke. Verify this in your own terminal session before enabling automatic submission.
- A terminal can show its own confirmation for multiline paste. Inspect the terminal if the text does not appear. You can always copy the translation and paste it manually.
- Clipboard preservation supports up to 64 MiB per paste operation. For larger clipboards, use **Copy Translation** and paste manually.
- Use backticks around paths, variable names, and commands you want to keep intact. If Apple Translation changes a code placeholder, the app translates the surrounding text in segments.
- Moving or replacing the app may require you to grant Accessibility again. If permissions appear enabled and pasting still fails, quit InputTranslator, remove the old Accessibility entry, add the current copy from Applications, and reopen it. For a local build, select the copy you actually run.

## Contribute

See the [contribution guide](CONTRIBUTING.md) for bug reports and pull requests, or the [security policy](SECURITY.md) for private vulnerability reporting.
