# Client Self-Optimization Log

This document records autonomous client improvements so the final summary does
not lose detail. All changes should continue to follow
`docs/client-mail-decisions.md`: local-first mail access, direct provider
communication, cached message lists before remote refreshes, sanitized message
rendering, undo windows for destructive actions, and no checks that require a
real mailbox unless explicitly requested.

## 2026-07-09 Round 1 - Mail Client Familiarity

Focus: make the unlocked mailbox surface feel closer to a mainstream desktop
and mobile mail client while keeping the existing local-first architecture.

Implemented:

- Added a central unlocked-mailbox shortcut layer that is active on the main
  mail surface and yields to text inputs:
  - Ctrl/Cmd+N opens compose when at least one mailbox exists.
  - Ctrl/Cmd+F focuses and selects the mail search field.
  - Ctrl/Cmd+A selects all visible messages, but not while editing text.
  - Ctrl/Cmd+R and F5 refresh mail.
  - Delete/Backspace moves the current selection or current message to Trash
    through the existing undoable delete flow.
  - Escape clears multi-selection.
- Added a shared `FocusNode` for the message-list search field so desktop and
  mobile list surfaces can be focused consistently by the shortcut layer.
- Improved message-list empty states:
  - No accounts now offers an Add mailbox action directly in the list area.
  - No search results now offers Clear search.
  - Empty folders now offer Refresh.
- Reworked message rows toward common email-client scanning:
  - Sender is now the primary line.
  - Date, star, pin, and attachment indicators sit in the top row.
  - Subject and preview are combined below the sender.
  - Read status and the account pill remain available without taking over the
    main scanning line.

Validation:

- `dart analyze --no-fatal-warnings` was run through the cached Dart SDK with
  `APPDATA` redirected to `C:\tmp\codex-dart-appdata`; it completed with exit
  code 0. It reported existing informational warnings, mostly deprecated
  `RegExp implements Pattern` usage and two existing async `BuildContext`
  lints, but no errors.
- `git diff --check` passed; Git warned only that line endings may be converted
  from LF to CRLF when Git next touches the edited Dart file.
- `dart format` could not overwrite `lib/src/ui/mail_home_page.dart` from the
  sandboxed Dart process because Windows returned access denied. Formatting was
  therefore kept manual for the touched sections.
- `flutter test --no-pub` could not be completed in this environment. Running
  the normal Flutter batch wrapper waited on the Flutter tool lock; running the
  Flutter tool directly with sandbox escalation exposed a local SDK/cache
  mismatch: cached Flutter packages require Dart language version 3.10+, while
  the directly available cached Dart SDK is 3.9.2. The failing test process was
  stopped to avoid continuous error output.

Next candidates:

- Add a compact quick-action strip or overflow menu near the selected message
  list item for desktop users who do not discover right-click.
- Add an account/folder search filter in the sidebar once folder counts or
  large folder lists become painful.
- Consider a safer, documented Flutter SDK invocation path for this machine so
  `flutter test --no-pub` and `dart format` can run without lock/cache issues.

## 2026-07-09 Round 2 - Discoverable Per-Message Actions

Focus: make common actions available without requiring users to discover
right-click, long-press, swipe gestures, or keyboard shortcuts.

Implemented:

- Added a per-message overflow menu to normal list rows.
- The menu exposes available actions for the row using the existing action
  pipeline and applicability rules:
  - Mark read / mark unread.
  - Star / unstar.
  - Pin.
  - Archive when the message is not already archived.
  - Move to inbox when the current mailbox supports that return path.
  - Delete when the message is not already in Trash.
- The menu is hidden while multi-select mode is active, keeping batch selection
  focused on the existing batch toolbar.
- The implementation reuses the same local undo, provider commit, and failure
  handling paths as swipes, context menus, and batch actions.

Validation:

- `dart analyze --no-fatal-warnings` completed with exit code 0 after the
  change. The analyzer still reports the same existing informational warnings
  noted in Round 1, with no new errors.

## 2026-07-09 Round 3 - Easier Account Growth

Focus: reduce the feeling that mailbox management is hidden behind global
settings.

Implemented:

- Added an Add mailbox icon button to the Accounts header in the folder sidebar.
- The button is available in both the wide desktop sidebar and the drawer-style
  sidebar used on narrower layouts.
- The button reuses the existing `_showAddMailbox` flow, so OAuth setup,
  encrypted vault storage, local application, and optional server sync behavior
  remain unchanged.

Validation:

- `dart analyze --no-fatal-warnings` completed with exit code 0. Existing
  informational warnings remain unchanged in kind; no new analyzer errors were
  introduced.

## 2026-07-09 Round 4 - Cleaner Compose Defaults

Focus: make the new-message dialog feel lighter for ordinary messages while
preserving full addressing controls when needed.

Implemented:

- Cc and Bcc fields now start collapsed for a new compose window when both are
  empty.
- A compact Cc/Bcc action reveals both fields.
- If a saved draft, forward, or other initial state contains Cc or Bcc values,
  the fields open automatically so no existing recipient data is hidden.
- Draft persistence and send validation still read the same controllers, so the
  underlying send behavior did not change.

Validation:

- `dart analyze --no-fatal-warnings` completed with exit code 0. Existing
  informational warnings remain; no new analyzer errors were introduced.

## 2026-07-09 Round 5 - Better Current Folder Context

Focus: keep the user's current mailbox context visible when the folder sidebar
is collapsed into a drawer.

Implemented:

- The top bar now shows the current mailbox/folder label whenever the folder
  drawer is in use.
- Full-width layouts that keep the sidebar visible still show the simpler
  product title, because the highlighted sidebar already provides context.
- The compact mobile title continues to use the same current mailbox label.

Validation:

- `dart analyze --no-fatal-warnings` completed with exit code 0 after removing
  the now-unused compact-shell local variable. Existing informational warnings
  remain; no new analyzer errors were introduced.

## 2026-07-09 Round 6 - Keyboard Message Navigation

Focus: make desktop reading feel closer to a mainstream mailbox where the
message list and reader can be driven without reaching for the mouse.

Implemented:

- Added Arrow Down / Arrow Up shortcuts to move the selected message in the
  list.
- Navigation is active only when the reader pane is visible, so narrow/mobile
  layouts keep their explicit tap-to-open behavior.
- Navigation yields to text inputs and does nothing during multi-select mode,
  avoiding conflicts with editing and batch-selection workflows.
- Moving selection reuses `_selectMessage`, so it preserves existing behavior:
  the reader updates, the full message body loads on demand, and unread
  messages are marked read through the same local-first optimistic path.

Validation:

- `dart analyze --no-fatal-warnings` completed with exit code 0. Existing
  informational warnings remain; no new analyzer errors were introduced.

## 2026-07-09 Round 7 - Friendlier Reader Empty State

Focus: make the desktop reader pane feel intentional before a message is
selected, instead of looking like an unfinished blank panel.

Implemented:

- Replaced the bare `Select a message` text in the reader pane with a centered
  empty state.
- Added a mail icon, a title, and quiet supporting copy so the two-pane desktop
  layout has a more polished resting state.
- Kept this purely presentational; message loading, sanitized rendering,
  remote-image gating, and attachment behavior are unchanged.

Validation:

- `dart analyze --no-fatal-warnings` completed with exit code 0. Existing
  informational warnings remain; no new analyzer errors were introduced.

## 2026-07-09 Round 8 - Folder Sidebar Search

Focus: make the client scale better for real mailboxes with many labels,
provider folders, and multiple accounts.

Implemented:

- Converted the mailbox sidebar into a small stateful surface with a local
  folder search field.
- Search filters smart folders, account names, account addresses, provider
  names, folder display names, decoded folder paths, and mailbox-kind labels.
- Matching accounts stay visible; when an account itself matches, its folders
  remain visible for context.
- Account sections expand automatically while a filter is active so matching
  folders are not hidden behind collapsed account groups.
- Added a clear-search icon and a quiet no-results state.
- Kept the filter purely local to the sidebar. It does not alter the active
  mailbox view, message search query, cached message loading, or provider
  refresh behavior.

Validation:

- `dart analyze --no-fatal-warnings` completed with exit code 0. Existing
  informational warnings remain; no new analyzer errors were introduced.

## 2026-07-09 Round 9 - Honest Pin and Unpin Actions

Focus: make toggle-style message actions say what will actually happen.

Implemented:

- Message row overflow menus now show `Unpin` with a filled pin icon when the
  row is already pinned.
- Desktop context menus use the same pinned-state-aware label and icon.
- Batch selection now shows `Unpin` when every selected message is pinned, and
  keeps `Pin` when at least one selected message is not pinned.
- The underlying local settings persistence, undo behavior, and display sort
  for pinned messages are unchanged.

Validation:

- `dart analyze --no-fatal-warnings` completed with exit code 0. Existing
  informational warnings remain; no new analyzer errors were introduced.

## 2026-07-09 Round 10 - Visible Compose Draft Status

Focus: make composing feel safer by acknowledging that local draft persistence
is working.

Implemented:

- Added a small compose-dialog status label for local draft saves.
- While typing, the dialog can now show `Saving draft...`.
- After a successful local draft write, it shows `Draft saved locally`.
- If draft persistence fails, it shows `Draft not saved` in the theme error
  color.
- The status is hidden while sending so it does not compete with the primary
  send progress state.
- The draft cache format, send validation, send API, and local-only draft
  behavior remain unchanged.

Validation:

- `dart analyze --no-fatal-warnings` completed with exit code 0. Existing
  informational warnings remain; no new analyzer errors were introduced.

## 2026-07-09 Round 11 - Attachment-Safe Local Drafts

Focus: make compose drafts match normal user expectations: if a message draft
is restored, its attachments should come back too.

Implemented:

- Extended `MailDraft` with a local-only `attachments` list.
- Added `MailDraftAttachment` with filename, content type, and base64-encoded
  bytes in the draft JSON payload.
- Empty-draft detection now treats attachments as real draft content, so an
  attachment-only draft is not deleted.
- Compose restoration now recreates `OutgoingAttachment` values from the saved
  local draft.
- Adding or removing compose attachments now schedules a draft save.
- Draft attachment decoding is tolerant of malformed base64 for a single
  attachment, returning empty bytes rather than failing the whole draft load.
- The existing optional local-cache encryption wrapper is unchanged, so saved
  draft attachments are encrypted whenever the draft cache has a local cache
  secret.
- Updated `test/mail_draft_cache_test.dart` to cover attachment round-trip and
  to assert encrypted raw draft content does not expose the attachment filename.

Validation:

- `dart analyze --no-fatal-warnings` completed with exit code 0. Existing
  informational warnings remain; no new analyzer errors were introduced.
- Attempted `dart test test/mail_draft_cache_test.dart` through the cached Dart
  SDK, but this machine's directly available Dart SDK is 3.9.2 while the
  project dependency `flutter_local_notifications 22.0.1` requires Dart
  `^3.10.0`. Version solving failed before tests could run. This is the same
  local SDK/cache class of limitation already noted earlier for Flutter tests.

## 2026-07-09 Round 12 - Draft Status After Failed Send

Focus: keep compose status truthful when sending fails and the user remains in
the dialog.

Implemented:

- Audited the new draft status path and found a case where `_sending` hid the
  status while `_saveDraftNow` skipped resetting its state.
- Changed `_saveDraftNow` to update its internal saved/failed status even while
  the send spinner is active. The label is still hidden during send, but if
  sending fails and the dialog stays open, the visible draft state is no longer
  stuck on `Saving draft...`.
- This is UI-state-only; draft persistence, send validation, and send transport
  behavior are unchanged.

Validation:

- `dart analyze --no-fatal-warnings` completed with exit code 0. Existing
  informational warnings remain; no new analyzer errors were introduced.

## 2026-07-09 Final Validation Pass

Focus: leave the working tree in a reviewable, non-committed state with the
available checks recorded.

Validation:

- Ran `dart format` on:
  - `lib/src/mail/mail_draft_cache.dart`
  - `lib/src/ui/mail_home_page.dart`
  - `test/mail_draft_cache_test.dart`
- The sandboxed formatter process could format the test file but hit Windows
  access denied while trying to overwrite the two source files. The same
  formatter command was rerun with filesystem escalation for those workspace
  writes, and it completed successfully.
- Re-ran `dart analyze --no-fatal-warnings`; exit code 0. The analyzer still
  reports existing informational warnings, primarily deprecated `RegExp`
  usage and the existing async `BuildContext` lints, but no errors.
- Ran `git diff --check`; exit code 0. Git warned only that line endings may
  be converted from LF to CRLF when Git next touches two edited Dart files.
- `dart test test/mail_draft_cache_test.dart` remains blocked by the local
  Dart SDK version mismatch noted in Round 11: cached Dart is 3.9.2, while a
  resolved dependency requires `^3.10.0`.
- No git commit was made.

Remaining low-priority ideas:

- Add a richer batch `Move to...` menu if batch triage needs Spam/custom-folder
  moves from the list.
- Add visual auto-scroll for keyboard Arrow Up/Down navigation if selection can
  move outside the visible message-list viewport.
- Revisit existing `RegExp` deprecation warnings as a maintenance task once the
  SDK/toolchain target is settled.

## 2026-07-10 Round 13 - Batch Move To

Focus: make multi-message triage behave more like a mainstream mail client
when the desired destination is not simply Archive, Inbox, or Trash.

Implemented:

- Added a `Move to...` menu to the multi-select toolbar on both desktop and
  mobile message lists.
- The menu offers standard mailbox destinations that would change at least one
  selected message, including Inbox, Sent, Drafts, Archive, Spam, and Trash.
- Selecting a destination uses the existing `_scheduleMoveToMailboxMessages`
  path, preserving the local optimistic update, short undo window, provider
  commit, and failure recovery behavior used by reader-level moves.
- Batch selection clears after the move command, matching the existing batch
  archive, delete, star, read, and pin workflows.
- This does not introduce a second message-move API, does not require a live
  mailbox for verification, and does not change the local-first architecture.

Validation:

- Formatted `lib/src/ui/mail_home_page.dart` with the workspace Flutter Dart
  SDK.
- `flutter analyze --no-pub` completed with exit code 0 and reported no issues.
- `flutter test --no-pub test/mail_draft_cache_test.dart` completed with exit
  code 0: 5 tests passed.

## 2026-07-10 Round 14 - Visible Keyboard Navigation

Focus: keep desktop Arrow Up/Down navigation understandable when the selected
message crosses the message-list viewport boundary.

Implemented:

- Keyboard-driven selection now carries its target message and direction to
  the message list without changing normal tap-selection behavior.
- The list uses Flutter's keep-visible alignment policies to reveal the target
  row smoothly at the appropriate viewport edge.
- A small estimated-offset fallback handles a target row that has not yet been
  built by the lazy list, such as rapid keyboard navigation through a longer
  mailbox.
- Row keys are retained only for messages still visible in the current list,
  preventing an unbounded key map as views or search results change.
- The existing desktop-only shortcut guard, text-input guard, on-demand body
  loading, read marking, and mobile tap-to-open behavior remain unchanged.

Validation:

- Formatted `lib/src/ui/mail_home_page.dart` with the workspace Flutter Dart
  SDK.
- `flutter analyze --no-pub` completed with exit code 0 and reported no issues.
- `flutter test --no-pub test/mail_draft_cache_test.dart` completed with exit
  code 0: 5 tests passed.

## 2026-07-10 Round 15 - Rich-Text Draft Fidelity

Focus: preserve the formatting users create in the rich compose editor when a
local draft is saved and restored.

Implemented:

- Added `htmlBody` to `MailDraft` JSON as the optional `html_body` field while
  retaining the existing plain-text `body` field for compatibility and fallback.
- Compose autosave now persists both normalized text and editor HTML; restored
  compose windows initialize the rich editor with saved formatting instead of
  converting every draft back to plain text.
- The editor initial HTML is now Base64-encoded before it is placed in the
  WebView document script, avoiding direct HTML/script-literal interpolation.
- The editor calls its existing sanitizer immediately after restoring initial
  HTML, before the user sees or interacts with it. Scripts, active content,
  remote sources, unsafe URLs, and inline event handlers remain blocked by the
  existing editor policy.
- Old draft JSON without `html_body` loads unchanged as a plain-text draft.
- Attachment draft persistence and encrypted local-cache wrapping are unchanged.

Validation:

- Formatted the touched UI and test files with the workspace Flutter Dart SDK.
- `flutter analyze --no-pub` completed with exit code 0 and reported no issues.
- Extended `test/mail_draft_cache_test.dart` with formatted HTML round-trip and
  legacy plain-text JSON coverage.
- `flutter test --no-pub test/mail_draft_cache_test.dart` completed with exit
  code 0: 6 tests passed.

## 2026-07-10 Round 16 - Reliable Concurrent Draft Saves

Focus: make local drafts dependable during rapid editing, where a previous
asynchronous save can overlap with a newer one.

Implemented:

- Added a per-draft-file async mutex to `MailDraftCache`, matching the
  established locking approach used by the message cache.
- Loads, saves, deletion, and namespace clearing now run through the same
  file-specific queue.
- Split internal deletion into an unlocked helper so saving an empty draft does
  not recursively acquire the same mutex.
- This serializes replacement of the shared `compose.json.tmp` file and makes
  writes complete in invocation order, so the later draft wins predictably.
- Added a test that starts two compose saves together and verifies the second
  save is the persisted draft.

Validation:

- Formatted `lib/src/mail/mail_draft_cache.dart` and the draft cache tests.
- `flutter analyze --no-pub` completed with exit code 0 and reported no issues.
- `flutter test --no-pub test/mail_draft_cache_test.dart` completed with exit
  code 0: 7 tests passed.

## 2026-07-10 Round 17 - Reader Mailbox Context

Focus: retain account and folder awareness after opening a message, especially
on the mobile full-screen reader where the folder sidebar is no longer visible.

Implemented:

- Added a compact folder-icon metadata line below the reader headers.
- The line identifies the message as `In account / folder`, resolving the
  account display name from current mailbox data and using the explicit folder
  name, folder path, or standard mailbox label as an appropriate fallback.
- Applied the same context to the desktop two-pane reader and the mobile
  full-screen reader.
- This reads only existing local message/account metadata; it does not change
  message loading, cached headers, remote refreshes, sanitization, or mail
  actions.

Validation:

- Formatted `lib/src/ui/mail_home_page.dart` with the workspace Flutter Dart
  SDK.
- `flutter analyze --no-pub` completed with exit code 0 and reported no issues.
- `flutter test --no-pub` completed with exit code 0: 194 tests passed, with no
  live mailbox required.

## 2026-07-10 Continuation Validation Pass

Focus: leave the continued optimization work in a reviewable, non-committed
state and distinguish completed low-risk improvements from broader product
work.

Validation:

- Used the workspace Flutter SDK and project-local cache settings, avoiding the
  older standalone Dart SDK mismatch recorded in the prior validation pass.
- `flutter analyze --no-pub` completed with exit code 0 and reported no issues.
- `flutter test --no-pub` completed with exit code 0: 194 tests passed. No
  test required a real mailbox, sent mail, or networked provider access.
- `git diff --check` completed with exit code 0. Git only warned that two Dart
  files may be converted from LF to CRLF when Git next touches them.
- No git commit was made.

Completion audit:

- The prior low-risk candidates for a batch `Move to...` menu and visible
  keyboard navigation are now implemented in Rounds 13 and 14.
- The remaining noticeable mail-client gaps are broader feature work rather
  than safe incremental polish: CID inline image rendering needs MIME
  `Content-ID` preservation plus attachment fetch/render support; moving to
  arbitrary provider folders needs an expanded repository/transport move API;
  conversation threading needs a message data-model and list-rendering design.
- Those larger changes are deliberately deferred so this autonomous pass does
  not invent provider behavior or weaken the local-first/sanitized-rendering
  decisions.
