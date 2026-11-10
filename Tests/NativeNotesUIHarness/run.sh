#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
notes_scratch="${LINENOTES_SWIFT_SCRATCH_PATH:-$PWD/.build}"
notes_module_cache="${LINENOTES_MODULE_CACHE_PATH:-$notes_scratch/ModuleCache}"
notes_test_output="${LINENOTES_TEST_OUTPUT_DIR:-${TMPDIR:-/tmp}}"
export CLANG_MODULE_CACHE_PATH="$notes_module_cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$notes_module_cache"
notes_spm_options=(--scratch-path "$notes_scratch" --disable-sandbox)
for option in cache config security; do
    variable="LINENOTES_SWIFTPM_$(echo "$option" | tr '[:lower:]' '[:upper:]')_PATH"
    if [[ -n "${!variable:-}" ]]; then notes_spm_options+=("--$option-path" "${!variable}"); fi
done
swift build "${notes_spm_options[@]}"
notes_bin="$(swift build "${notes_spm_options[@]}" --show-bin-path)"
mkdir -p "$notes_test_output"
notes_harness="$(mktemp -d "$notes_test_output/LineNotes-ui-harness.XXXXXX")"
trap 'rm -rf "$notes_harness"' EXIT
notes_objects=()
for module in NotesCore SwiftSoup; do
    notes_previous_count=${#notes_objects[@]}
    if [[ -f "$notes_bin/$module.o" ]]; then
        notes_objects+=("$notes_bin/$module.o")
    else
        while IFS= read -r object; do notes_objects+=("$object"); done < <(rg --files "$notes_scratch" | rg "$module.build/.*\\.swift.o$")
    fi
    if [[ ${#notes_objects[@]} -eq $notes_previous_count ]]; then
        echo "Unable to locate compiled $module objects" >&2
        exit 1
    fi
done
swiftc -parse-as-library -module-cache-path "$notes_module_cache" -module-name LineNotesUIHarness -I "$notes_bin" -I "$notes_bin/Modules" \
    "${notes_objects[@]}" \
    Sources/Tendedero/NotesAppIcon.swift Sources/Tendedero/NotesImageCache.swift Sources/Tendedero/NotesTooltip.swift Sources/Tendedero/NotesTheme.swift Sources/Tendedero/NotesPalette.swift Sources/Tendedero/NotesEditorPaper.swift Sources/Tendedero/NotesScrollChrome.swift Sources/Tendedero/NotesEditorTransition.swift Sources/Tendedero/NotesInteraction.swift Sources/Tendedero/NotesMenu.swift Sources/Tendedero/NotesTextMenu.swift Sources/Tendedero/NoteThumbnail.swift \
    Sources/Tendedero/NotesWebLink.swift Sources/Tendedero/NotesLinkTitleResolver.swift Sources/Tendedero/NotesLinkMetadata.swift Sources/Tendedero/NotesLinkPasteController.swift \
    Sources/Tendedero/NotesEditorSession.swift Sources/Tendedero/NotesEditorPasteboard.swift Sources/Tendedero/RichNoteTextView.swift Sources/Tendedero/NotesListEditing.swift Sources/Tendedero/NotesContinuousDocument.swift Sources/Tendedero/NotesContinuousTextView.swift Sources/Tendedero/NotesContinuousBody.swift Sources/Tendedero/NotesEditorContextTools.swift Sources/Tendedero/NotesEditorFormatMenu.swift Sources/Tendedero/NotesImagePreview.swift \
    Sources/Tendedero/NotesWorkspace.swift Sources/Tendedero/NotesEmptyTrashConfirmation.swift Sources/Tendedero/NotesEditorResize.swift Sources/Tendedero/NotesEditorIcon.swift Sources/Tendedero/NoteEditorView.swift \
    Sources/Tendedero/NotesLibraryView.swift Sources/Tendedero/NotesSettingsView.swift Sources/Tendedero/RopeFoldingPreferences.swift \
    Tests/NativeNotesUIHarness/DurabilityProbe.swift Tests/NativeNotesUIHarness/LinkMetadataProbe.swift Tests/NativeNotesUIHarness/main.swift -o "$notes_harness/check"
"$notes_harness/check" "$@"
