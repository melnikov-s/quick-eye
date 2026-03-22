# Quick Eye

Quick Eye is a macOS-first screenshot annotation tool built for fast UI feedback loops with LLM agents.

## Why native Swift instead of Tauri?

This app's value lives in system-level behavior:

- A global hotkey that works even when the app is in the background.
- Fast screen capture with macOS Screen Recording permissions.
- A fullscreen overlay window for immediate annotation.
- Copying the finished image straight to the clipboard.

Those workflows are much more direct in AppKit than in a webview shell. Tauri could still work later if we want a cross-platform shell, but a native macOS MVP is the fastest path to the "press hotkey, mark it up, paste it" experience.

## MVP flow

1. Launch the app.
2. Press `Control + Option + Command + 4`.
3. Quick Eye captures the display under your cursor.
4. Drag to draw an arrow.
5. Type a note in the popup and press `Add`.
6. Press `Done`.
7. The annotated screenshot is copied to your clipboard, ready to paste into ChatGPT, Codex, Slack, or anywhere else.

## Current implementation

- Menu bar app with `Capture Screen` and `Quit`.
- Global hotkey registration through Carbon.
- Display capture via Core Graphics.
- Fullscreen overlay annotation surface.
- Fullscreen overlay annotation surface.
- Arrow drawing with inline text prompts.
- Clipboard export on completion.

## Running

```bash
swift run
```

The first capture will likely trigger macOS Screen Recording permission prompts. If capture fails, enable access for your terminal or the final app inside System Settings -> Privacy & Security -> Screen Recording.

## Next steps

- Persist a user-configurable hotkey.
- Add rectangle highlights and freehand sketching.
- Support multi-monitor composite capture.
- Package as a proper `.app` bundle with app icon and launch-at-login behavior.
- Add direct paste/upload integrations for your favorite agent tools.
