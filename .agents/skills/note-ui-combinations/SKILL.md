---
name: note-ui-combinations
description: Visually test every valid combination of note content and attachment features across the note editor with the software keyboard shown, the note editor with the keyboard dismissed, and the day view. Use after changing note layout, editing, attachments, checklists, keyboard toolbars, voice memos, transcripts, media, documents, or shared note-card styling, and whenever asked to check mixed-content notes for clipping, overlap, inaccessible controls, or other UI regressions.
---

# Note UI Combination Testing

Test real rendered UI on an iPhone simulator or device. A successful build is necessary but never sufficient.

## Build the matrix

1. Inspect `Note`, `NoteBlock`, `NoteAttachment`, the editor, and the day card before each full run. Treat the code as the source of truth because note features evolve.
2. List independent feature axes and meaningful states. At minimum include:
   - normal text: absent, one row, multiline/long
   - checklist: absent, unchecked, checked, mixed, nested when supported
   - visual media: absent, one image, multiple images, video when supported
   - documents: absent, one, multiple
   - voice memos: absent, one, multiple, recording state when testable
   - transcript: absent, short, collapsed long, expanded long, loading, error
3. Generate every valid presence/absence combination of independent feature types. For stateful variants, cover every state alone and in the densest mixed-content combination. Exclude only combinations that the product model cannot represent; record the reason.
4. If the user requests a focused subset, run that subset now and preserve the full matrix for comprehensive runs.

Use this canonical baseline for mixed-content smoke tests unless the user specifies another fixture:

- one picture
- one normal text row
- two checklist rows, one unchecked and one checked
- one voice memo with a representative waveform

## Prepare fixtures safely

- Never use or alter the user's persisted notes.
- Prefer a test-only launch argument or environment variable that seeds deterministic in-memory content in debug builds.
- If no fixture hook exists, create the note through the UI and delete it after evidence is collected.
- Use bundled or generated test media with known dimensions. Do not depend on a personal photo library or microphone recording.
- Keep fixture-only code out of release behavior. Remove temporary fixture code after the run unless the user explicitly requests permanent test infrastructure.

## Test every fixture on three surfaces

Always inspect each fixture in this order:

1. **Editor, keyboard shown**
   - Focus the text editor and verify the software keyboard and keyboard toolbar are visible.
   - Verify attachments and voice memos remain above the keyboard toolbar and are not obscured.
   - Open the unified add menu and verify all actions are readable, enabled appropriately, and dismiss cleanly.
2. **Editor, keyboard dismissed**
   - Use the editor's keyboard-dismiss button rather than a simulator shortcut.
   - Verify content expands into the reclaimed space without jumping, clipping, or leaving stale padding.
3. **Day view**
   - Save or close the editor and inspect the resulting note card.
   - Verify ordering, rounding, media cropping, checklist alignment, voice memo glass, and card clipping.

For every surface, capture both a screenshot and the accessibility hierarchy after animations settle. Use hierarchy hit points for interaction; do not guess coordinates unless hierarchy interaction fails once.

## Visual and interaction assertions

Fail the case for any of the following:

- content overlaps the keyboard, keyboard toolbar, safe areas, another attachment, or card chrome
- content is unexpectedly clipped, truncated, off-screen, or hidden beneath rounded corners
- the editor cannot scroll every element into view
- toolbar items disappear, overflow incorrectly, or have ambiguous tap targets
- the keyboard-dismiss button is not centered or does not dismiss the keyboard
- Liquid Glass surfaces lose their shape, contrast, or separation from surrounding content
- image aspect fill/crop is visibly broken
- text and checklist rows reorder, merge, or lose indentation/state
- voice memo controls, waveform, duration, transcript, or contextual actions are missing or untappable
- save/dismiss changes or loses fixture content
- accessibility labels are missing or misleading for interactive controls

Exercise the play/pause, restart, checklist toggle, transcript disclosure, add menu, keyboard dismiss, Cancel, and Done controls when present. Report functional and visual defects separately.

## Evidence and report

Produce a compact result table with one row per fixture and columns for editor/keyboard, editor/no keyboard, and day view. Mark each cell pass, fail, or blocked. For failures include:

- the exact fixture and surface
- screenshot or artifact path
- observed behavior and expected behavior
- relevant accessibility frames when overlap or hit testing is involved
- likely owning view/file, clearly labeled as an inference

Do not claim a visual pass from source inspection, previews, or a successful build alone. End the device session after collecting evidence.
