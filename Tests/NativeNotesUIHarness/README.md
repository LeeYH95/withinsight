# Native notes session checks

Run from the native LineNotes repository:

```sh
Tests/NativeNotesUIHarness/run.sh
```

This compiles the real native UI files and NotesCore, then runs an isolated AppKit harness. It does not open or automate the user's application, use personal notes, read screenshot folders, or touch screenshot settings. All fixture data lives in a unique temporary directory.

The checks exercise document undo/redo, attachment removal followed by atomic save and repeated undo restoration, unchanged source file bytes, independent undo histories, actual NSTextView font attributes and selection, Markdown conversion, AppKit marked text deferral during the autosave interval, a deliberately blocked store write and successful retry, and native body/title Edit menu selectors.

Review regressions include a real file obstructing the session backup directory: both import undo and an older history snapshot are blocked from cleaning the only owned copy, then retry and redo restore the bytes after the obstruction is removed. They also cover undo and redo while the atomic store write is blocked, retryable attachment restoration, splitting rich text at the actual selection for attachment insertion, one-operation insertion undo, preserving mixed inline emphasis when toggling bullets, valid Markdown list syntax and emphasis whitespace, attachment export errors staying separate from body-save errors, and borderless close / Escape delegating to the save protocol.

The marked-text check invokes AppKit's marked-text API. It verifies that the autosave code leaves composition intact; it does not prove behavior with every Chinese input method or simulate human keyboard composition. Window layout, native focus, actual keyboard routing, VoiceOver, drag and drop from Finder, display changes, and reduced motion need separate running-app validation.

The durability checks launch this same harness as isolated child processes, kill only those children with SIGKILL, and reopen their UUID-named fixture stores. They require the final title, Chinese body with real RTF and inline bold, checklist toggle, and attachment removal followed by save and undo to recover even when the process never runs the 650 ms autosave timer. The attachment case first proves that the saved removal collected the owned file, then requires undo recovery to restore its exact bytes without modifying the external source. Every crash fixture is reopened twice to check that recovery does not duplicate or change notes or attachments. Saved text/checklists/appearance/attachments, kills during repeated atomic writes, and two processes racing to save the same snapshot remain covered. Clean stale instances are checked for normal quit without rewriting a newer store.

These checks use completed editor-session mutation callbacks. They do not claim to recover an input method's unconfirmed candidate state, nor do SIGKILL tests establish durability under physical power loss, disk failure, or an unwritable/full disk. The product keeps local saving and short-lived interrupted-edit recovery; it no longer creates full archive backups.

The 0.2 interaction checks also use the actual custom menu presenter and a real SwiftUI TextField hosted in an NSWindow: source selection, Tab/IME routing, preserved native field-editor identity, targeted search context anchors, interrupted close/reopen, and reduced-motion final states. These do not replace the separate real-running-app QA record in `docs/native/INTERACTION-VALIDATION.md`.
