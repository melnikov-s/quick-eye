# Quick Eye

Quick Eye is a macOS-first screenshot annotation tool built for one job: giving LLMs visual context as quickly as possible.

This is not a general-purpose screenshot utility. It is not trying to be the best tool for sharing screenshots with coworkers, making polished presentations, or replacing a full image editor. It exists to make the "take screenshot -> mark up what matters -> paste into an agent" workflow as fast and frictionless as possible.

## Why This Exists

If you are working with an LLM on UI, layout, styling, or product changes, visual context matters. A lot.

You often want to say things like:

- "Move this button down."
- "Increase the spacing here."
- "Remove this element."
- "Use this style over there."
- "This section is broken."

You can already do that with the default screenshot tools on macOS. But the workflow is slower than it needs to be:

- take a screenshot
- open the editor
- pick an arrow tool
- draw it
- add text manually
- copy the result
- paste it into the LLM

That general-purpose flow works, but it is not optimized for agent handoff.

Quick Eye is optimized for a narrower, more specific workflow:

- capture fast
- annotate fast
- keep only the context that matters
- copy immediately
- paste directly into an LLM

That is the whole point of the project.

## Design Principle

Quick Eye is a small productivity tool. It is not revolutionary. The value is not novelty; the value is speed.

The guiding principle is:

> provide useful context to the LLM as quickly as possible

Everything in the app should support that outcome. If a feature does not help you communicate visual intent faster, it probably does not belong here.

## What It Optimizes For

Quick Eye is specifically optimized for screenshot-to-agent workflows:

- fast global capture from anywhere
- immediate annotation on top of the screenshot
- quick arrows, shapes, and notes
- copy-ready output with minimal ceremony
- auto-crop to reduce irrelevant visual context
- smaller, more targeted images that are better suited for LLM handoff

That last point matters. Often you do not need to send a full screen to an LLM. You only need the region that contains the issue, the note, and enough surrounding context to understand the request. Quick Eye tries to make that the default path when it helps.

## Current Features

- Menu bar app for fast access
- Global hotkey capture on macOS
- Fullscreen annotation overlay
- Arrow, box, circle, and freeform annotations
- Inline text entry for notes
- Stroke color picker for markup visibility
- Auto-crop export designed to keep relevant context while trimming noise
- Manual crop mode
- Undo and redo
- Select, move, and delete individual annotations
- History of the 10 most recent annotated captures
- Session restore from history, including undo/redo state
- Clipboard-first export so the result is ready to paste into an LLM immediately

## Typical Workflow

1. Launch the app.
2. Press `Shift + Command + 6`.
3. Capture the current screen.
4. Annotate the problem or desired change.
5. Add text that explains the request.
6. Press `Enter` to copy normally, or `Shift+Enter` to auto-crop and copy.
7. Paste the result into ChatGPT, Codex, or another agent.

## Why It Is Different From a General Screenshot Tool

A general screenshot tool has to optimize for many use cases:

- casual sharing
- documentation
- presentations
- bug reports
- team communication
- archival screenshots

Quick Eye does not.

Quick Eye is purpose-built around one use case:

- communicate visual intent to an LLM with the least possible friction

Because it has that narrower goal, it can optimize around behaviors that matter more in agent workflows than in general screenshot tools:

- fewer steps
- quicker markup
- faster note entry
- export paths that prioritize relevance over completeness
- history that lets you reopen and continue an unfinished visual explanation

## Running

```bash
swift run
```

The first capture will likely trigger macOS Screen Recording permission prompts. If capture fails, enable access for your terminal or the final app inside System Settings -> Privacy & Security -> Screen Recording.

## Status

Quick Eye is a practical productivity tool for a very specific workflow. That is the goal.

It is meant to help you move faster when collaborating with an LLM, not to become a full creative editing suite.
