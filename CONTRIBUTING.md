# Contributing to InputTranslator

## Report a bug or suggest a change

Use [GitHub Issues](https://github.com/akz142857/InputTranslator/issues) for bugs and feature requests. For a bug, include the InputTranslator and macOS versions, the steps to reproduce it, and the expected and observed behavior. If it involves translation or a terminal, include the language pair, terminal, and assistant involved. Use a short sample you can share publicly.

For a security issue, follow the [security policy](SECURITY.md).

## Build and test

Follow the [build instructions](README.md#build-from-source) and [test instructions](README.md#test) in the README. Use a local build for development. Developer ID signing and notarization are used for distribution.

For paste changes, test Terminal, iTerm2, Herdr, and standard native/browser text inputs. Verify window and split-pane changes, per-app submit settings and migration, and exclusion of password fields. For assistant reply reading, test Terminal and iTerm2 separately from general paste support. Check that a failed focus check preserves the translation, that multiline paste requires confirmation, and that clipboard restoration preserves text copied during the operation. For changes to translation, try a prompt with inline code, a fenced code block, and input method composition.

## Open a pull request

Describe the problem, the change, and how you tested it. Add a screenshot or recording for changes to the interface. Update the [English README](README.md) and [Chinese README](README.zh-CN.md) when a change affects installation or everyday use.

Keep local build products, assistant settings, credentials, and conversation logs out of the pull request.
