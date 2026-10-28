#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
notes_scratch="${LINENOTES_SWIFT_SCRATCH_PATH:-$PWD/.build}"
notes_module_cache="${LINENOTES_MODULE_CACHE_PATH:-$notes_scratch/ModuleCache}"
notes_test_output="${LINENOTES_TEST_OUTPUT_DIR:-${TMPDIR:-/tmp}}"
export CLANG_MODULE_CACHE_PATH="$notes_module_cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$notes_module_cache"
swift build --scratch-path "$notes_scratch" --disable-sandbox
notes_bin="$(swift build --scratch-path "$notes_scratch" --disable-sandbox --show-bin-path)"
mkdir -p "$notes_test_output"
notes_harness="$(mktemp -d "$notes_test_output/LineNotes-ui-harness.XXXXXX")"
trap 'rm -rf "$notes_harness"' EXIT
notes_objects=()
if [[ -f "$notes_bin/NotesCore.o" ]]; then
    notes_objects+=("$notes_bin/NotesCore.o")
else
    while IFS= read -r object; do notes_objects+=("$object"); done < <(rg --files "$notes_scratch" | rg 'NotesCore.build/.*\.swift.o$')
fi
if [[ ${#notes_objects[@]} -eq 0 ]]; then
    echo "Unable to locate compiled NotesCore objects" >&2
    exit 1
fi
swiftc -parse-as-library -module-cache-path "$notes_module_cache" -module-name LineNotesUIHarness -I "$notes_bin" -I "$notes_bin/Modules" \
    "${notes_objects[@]}" \
    Sources/Tendedero/NotesAppIcon.swift Sources/Tendedero/NotesImageCache.swift Sources/Tendedero/NotesTooltip.swift Sources/Tendedero/NotesTheme.swift Sources/Tendedero/NotesPalette.swift Sources/Tendedero/NotesEditorPaper.swift Sources/Tendedero/NotesScrollChrome.swift Sources/Tendedero/NotesEditorTransition.swift Sources/Tendedero/NotesInteraction.swift Sources/Tendedero/NotesMenu.swift Sources/Tendedero/NotesTextMenu.swift Sources/Tendedero/NoteThumbnail.swift \
    Sources/Tendedero/NotesWebLink.swift Sources/Tendedero/NotesLinkMetadata.swift Sources/Tendedero/NotesLinkPasteController.swift \
    Sources/Tendedero/NotesEditorSession.swift Sources/Tendedero/RichNoteTextView.swift Sources/Tendedero/NotesContinuousDocument.swift Sources/Tendedero/NotesContinuousTextView.swift Sources/Tendedero/NotesEditorFormatMenu.swift \
    Sources/Tendedero/NotesWorkspace.swift Sources/Tendedero/NotesEmptyTrashConfirmation.swift Sources/Tendedero/NotesEditorResize.swift Sources/Tendedero/NotesEditorIcon.swift Sources/Tendedero/NoteEditorView.swift \
    Sources/Tendedero/NotesLibraryView.swift Sources/Tendedero/NotesSettingsView.swift \
    Tests/NativeNotesUIHarness/DurabilityProbe.swift Tests/NativeNotesUIHarness/main.swift -o "$notes_harness/check"
"$notes_harness/check"
