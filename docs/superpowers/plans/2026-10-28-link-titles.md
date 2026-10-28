# Link title paste implementation plan

> Execute the approved inline title-link design in this chat. Use subagent-driven-development for the isolated metadata task and requesting-code-review for independent review. Preserve all existing untracked documents; no personal app replacement or remote publication is included.

**Goal:** Paste a single webpage URL, obtain its title without blocking editing, and preserve a usable link through editing, saving, copying and export.

**Architecture:** Keep the existing native attributed-string/RTF document. Add a small URL/title utility and cancellable Apple metadata service, then a view-local paste coordinator. Use temporary attributed markers to distinguish identical pasted URLs and reject stale responses. Optional copy-payload destinations preserve backward compatibility.

**Tech stack:** Swift/AppKit/TextKit, LinkPresentation, Combine.AnyCancellable, XCTest.

## Task 1: Isolated URL and metadata service

- [x] Write `Tests/LineIntegrationTests/WebLinkTests.swift` first. Assert a single trimmed HTTP(S) URL is accepted, multiple/mixed text and unsafe schemes/userinfo are rejected, title whitespace/control characters are normalized, and blank titles fail.
- [x] Observe the missing-API failure with `swift test --disable-sandbox --filter WebLinkTests` using the repo module-cache environment.
- [x] Add `Sources/Tendedero/NotesWebLink.swift` with `url(from:)`, `destination(from:)` and `normalizedTitle(_:)`.
- [x] Add `Sources/Tendedero/NotesLinkMetadata.swift`: `@MainActor static func fetchTitle(for:completion:) -> AnyCancellable`. Configure one LPMetadataProvider per request with `timeout = 8`, `shouldFetchSubresources = false`; return a cancellation closure and dispatch completion to main.
- [x] Run utility tests and review service scope/quality.

## Task 2: Paste, async replacement and persistence

- [x] Add `LinkTitlePasteTests.swift` with an injected callback loader before production integration. Example contract:

```swift
view.linkPastes.loadTitle = { url, completion in
    completions.append(completion)
    return AnyCancellable {}
}
```

- [x] Cover immediate URL insertion, result success/nil, independent identical URLs, preceding/following edits, deletion/edit/undo before completion, caret preservation, and RTF round-trip. Observe baseline failures.
- [x] Add `NotesLinkPasteController.swift`; use `paste(_:into:)`, temporary `.notesPendingLink` tokens, cancellable per-paste requests and `cancelAll()`.
- [x] Route raw single-URL clipboard contents through the controller in `NotesContinuousTextView`; preserve other paste routes. End typing groups for paste and title changes. Strip pending markers and link inheritance at insertion boundaries.
- [x] Remove temporary markers in `NotesContinuousDocument.blocks(from:)`; cancel pending work on document reload or editor removal.
- [x] Configure native link color and Command-click behavior explicitly, with an injectable URL opener for tests. Keep normal click in editing mode.
- [x] Run `swift test --disable-sandbox --filter LinkTitlePasteTests` and fix real behavior failures.

## Task 3: Link copy, rich paste and Markdown

- [x] Add failing cross-note clipboard and Markdown tests: styled linked text remains linked after source removal; dangerous schemes do not activate; `[`, `]`, parentheses and query strings export without losing the destination.
- [x] Extend `ClipboardStyle` with `link: String?`, defaulting to nil for old payloads. Write/restore safe destinations and validate during owned-payload decoding.
- [x] Preserve meaningful `.link` attributes through existing external rich paste and RTF export; remove unsafe attributes while keeping the text.
- [x] Update `RichNoteTextView.Coordinator.markdown(_:)` to render safe link runs as `[label](destination)` around existing inline formatting; plain non-link text stays identical.
- [x] Run link tests plus all ContinuousClipboard/ContinuousDocument tests.

## Task 4: Native verification and delivery

- [x] Update `Tests/NativeNotesUIHarness/run.sh` with the new native source dependencies; run full Swift tests and the native harness.
- [x] Obtain an isolated spec/quality review of the complete feature, resolve findings and rerun affected checks.
- [x] Build `拾片链接预览.app` with bundle ID `local.linenotes.linkqa`, launch only with `--demo --data-dir` in a new runtime directory, and paste a public URL into synthetic content.
- [x] Verify actual title replacement, Command-click, fallback, saving/reopening, copy/paste and undo. Save only synthetic evidence and a concise QA report.
- [x] Report tested behavior and live-network limits; leave the personal app and GitHub release unchanged for user acceptance.
