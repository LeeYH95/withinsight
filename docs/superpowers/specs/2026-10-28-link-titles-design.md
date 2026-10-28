# Paste a web URL as an inline title link

The user selected “网页标题文字链接，融入现有正文” after the proposed behavior: insert immediately, read the title in the background, preserve the URL on failure. This is the approved interaction direction.

## Behavior and scope

- When ordinary paste contains exactly one complete HTTP(S) URL, insert it immediately as an inline link. Trim clipboard boundary whitespace; do not reinterpret text containing a URL, multiple URLs, file URLs, or existing titled rich links.
- Fetch the page title with Apple's LinkPresentation metadata provider, with an 8-second timeout and subresources disabled. This uses no additional web service and downloads no preview icon/image/video by request. Metadata is best effort; failure, cancellation or an empty title leaves the original URL.
- Replace only the still-unchanged pasted URL with the title. Keep the original destination, even after redirects. Do not move focus or overwrite text entered before/after the link. Edited, deleted, undone or reloaded paste tokens must not be replaced by late results.
- Use the existing body font and theme accent/underline. Command-click opens the URL; normal interaction edits text. No card, image, new toolbar row or modal insertion flow.
- Preserve the destination in RTF saving/reopening, HTML/RTF paste, app-to-app and cross-note copy, and Markdown export as `[title](URL)`.
- Separate pasted content and automatic title replacement into clear undo boundaries. Undoing a title returns the original URL; undoing an in-flight paste must never resurrect it when the request finishes.
- Plain text outside a link must not inherit its target. No arbitrary URL scheme may be activated from a pasted rich link.

## Architecture

- `NotesWebLink.swift`: strict single-web-URL parsing, safe attributed-link destination extraction and title cleanup.
- `NotesLinkMetadata.swift`: one native LPMetadataProvider per request; returns a cancellable request and delivers normalized titles on the main actor.
- `NotesLinkPasteController.swift`: owns view-local request IDs, checks original content before applying results, adjusts current selection and ends undo groups around automatic replacement. Request markers are removed before persistence.
- Existing continuous editor routes only raw single-URL pastes to this controller; copy payload gains an optional destination per style run for backward compatibility. Existing RTF remains the storage format; no data migration.
- Markdown serializer retains inline link targets while preserving existing bold/italic/underline behavior. Link rendering/opening stays native.

## Validation

Use isolated stores and named pasteboards. Cover successful title replacement, timeout/failure fallback, destination persistence, undo/redo, deletion, edits inside and outside the pending URL, identical URLs pasted twice, title cleanup, invalid schemes, styled linked text copied across notes, and Markdown punctuation escaping.

Run targeted tests before the full Swift suite and native harness. Build a separate preview identity and use synthetic demo notes; test a public webpage title in the real app. Do not replace the running personal app or publish this feature remotely without a later explicit request.

Metadata API references: https://developer.apple.com/documentation/linkpresentation/lpmetadataprovider and https://developer.apple.com/documentation/linkpresentation/lpmetadataprovider/shouldfetchsubresources
