# Desktop sync protocol: what the hub would have to speak

Read on 2026-09-29 from the rTech Whisper desktop app, an OpenWhispr fork
([rodaddy/openwhispr](https://github.com/rodaddy/openwhispr), branch
`rtech-whisper`). The server it syncs with is
[rodaddy/rtech-whisper-hub](https://github.com/rodaddy/rtech-whisper-hub).

Sources read: `src/services/SyncService.ts`, `src/services/cloudApi.ts`,
the per-entity services it calls
(`NotesService`, `FoldersService`, `SpacesService`, `DictionaryService`,
`SnippetService`, `TranscriptionsService`, `ConversationsService`),
`src/services/noteListQuery.ts`, `src/services/syncPassPolicy.ts`,
`src/helpers/cloudApiRequest.js`, `src/helpers/cloudSyncGuards.js`,
`src/helpers/tokenStore.js`, and `src/helpers/policyRequestHeaders.js`.

The upstream OpenWhispr server is not in the repo. Everything below about the
server's behavior is inferred from what the client sends and how it reacts.

## 1. The fork has sync switched off today

The fork removed accounts, workspaces, billing, and the managed cloud. It
deleted the `cloudApiRequest` bridge from `preload.js` and its
`cloud-api-request` handler from `ipcHandlers.js`. `settingsStore.ts` pins
`isSignedIn` to `false`.

`SyncService.ts` and its callers (`noteStore`, `audioManager`, the note tools)
are still in the tree, but every pass returns before sending anything:
consent requires a validated auth context and `isSignedIn`
(`syncPassPolicy.ts` `resolveSyncConsent`). `createCloudApiRequestHandler` and
`tokenStore` survive and have tests.

Note sharing goes through its own `shareClient.js` IPC path to a separate
share service, not through `SyncService`.

Upstream's own phone app, `openwhispr-mobile/` on upstream `main` (Expo/React
Native, v1.1.0), is a working client of this same protocol
(`src/data/synced/SyncedNotesRepository.ts`). It is the reference for the
Swift client's behavior. It is read for reference only, never copied in.

## 2. Transport and auth

- Base URL: build-time `VITE_OPENWHISPR_API_URL` (`src/config/constants.ts`).
  The request path is appended to it, and cross-origin paths are rejected.
- Auth: `Authorization: Bearer <token>`. The token comes from `tokenStore`
  (`auth-token.bin` in userData, encrypted with Electron safeStorage).
  Cookies are never sent.
- Headers on every authenticated call: `x-openwhispr-version: <app version>`,
  `x-openwhispr-policy-version: 1`, and `Content-Type: application/json` when
  there is a body.
- `DELETE` requests carry a JSON body (`{ "id": ... }`), not a path id.
- Success is any 2xx with a JSON body. The body is returned as-is. Only the
  spaces endpoint wraps it as `{ data: ... }`.
- Errors: `401` means `AUTH_EXPIRED`. `503` means `SERVER_ERROR`. Any other
  non-2xx is read as `{ error: { message } | string, code, data,
  minAppVersion }`. The client branches on `code` and on the HTTP status.

## 3. Endpoints the sync engine calls

Timestamps are ISO 8601 with milliseconds and `Z`. Ids are server UUID
strings. Every row carries the client's own id (`client_*_id`), which is how
devices match rows.

### Spaces

| Method, path | Request | Response |
| --- | --- | --- |
| `GET /api/me/spaces` | – | `{ data: MySpace[] }` |

A `404` tells the client that team spaces are not deployed. It then syncs in
personal-only mode and sends no scope fields. `200 []` turns on team mode,
which adds `workspace_id: null, space_id: null` to every push. The fork has no
way to create a team space (`CreateSpaceDialog` was deleted), so the only
space is the local private one.

### Folders

| Method, path | Request | Response |
| --- | --- | --- |
| `GET /api/folders/list?since&scope` | `since` = cursor, `scope=all` only in team mode | `{ folders: CloudFolder[] }`, unpaginated, tombstones included |
| `POST /api/folders/batch-create` | `{ folders: [{ name, client_folder_id, is_default, sort_order }] }` | `{ created: CloudFolder[] }` in input order |
| `POST /api/folders/create` | same single object | `CloudFolder` |
| `PATCH /api/folders/update` | `{ id, name, sort_order }` | `CloudFolder` |
| `DELETE /api/folders/delete` | `{ id }` | any |

`CloudFolder` = `id, client_folder_id, name, is_default, sort_order,
workspace_id, space_id, deleted_at, created_at, updated_at`. Folder names are
unique per user. A clash returns `409` with `code: folder_name_taken`, except
that creating a same-named default folder returns the existing row, and the
client adopts its identity.

### Notes

| Method, path | Request | Response |
| --- | --- | --- |
| `GET /api/notes/list` | snapshot: `limit, before, before_id` (created_at descending); delta: `limit, since, since_id` (updated_at ascending); optional `scope=all` | `{ notes: CloudNote[] }`, page size 50, a short page ends the pass, tombstones included |
| `POST /api/notes/batch-create` | `{ notes: NoteInput[] }` | `{ created: [{ client_note_id, id, updated_at }] }` |
| `POST /api/notes/create` | `NoteInput` | `CloudNote` |
| `PATCH /api/notes/update` | `{ id, ...full note payload, base_updated_at? }` | `CloudNote` |
| `DELETE /api/notes/delete` | `{ id }` | any |

Note payload (`cloudSyncGuards.js` `buildNoteUpdatePayload`): `title,
content, enhanced_content, enhancement_prompt, enhanced_at_content_hash,
note_type, source_file, audio_duration_seconds, transcript, participants,
calendar_event_id, diarization_enabled, expected_speaker_count, folder_id`
(the cloud folder id), `updated_at`, and `base_updated_at` (the server
revision this device last acknowledged). Creates add `client_note_id` and
`created_at`, and drop `updated_at` and `base_updated_at` so the server stamps
the row.

`CloudNote` = the payload fields plus `id, client_note_id, workspace_id,
space_id, user_id, updated_by_user_id, deleted_at, created_at, updated_at`.

### Dictionary

| Method, path | Request | Response |
| --- | --- | --- |
| `GET /api/dictionary/list?since&since_id&limit` | limit 200, ascending by (updated_at, id) | `{ entries, hasMore }` |
| `POST /api/dictionary/batch-create` | `{ entries: [{ client_dict_id, word, source, created_at, updated_at }] }` | `{ created: CloudDictionaryEntry[] }` |
| `PATCH /api/dictionary/update` | `{ id, word, source }` | `CloudDictionaryEntry` |
| `DELETE /api/dictionary/delete` | `{ id }` | any |

`source` is `manual` or `learned`.

### Snippets

| Method, path | Request | Response |
| --- | --- | --- |
| `GET /api/snippets/list` | snapshot: `cursor, cursor_id, limit` (created_at); delta: `since, since_id, limit` (updated_at); limit 200 | `{ entries, hasMore }` |
| `POST /api/snippets/batch-create` | `{ entries: [{ client_snippet_id, trigger, replacement, created_at, updated_at }] }` | `{ created: CloudSnippetEntry[] }` |
| `PATCH /api/snippets/update` | `{ id, trigger, replacement }` | `CloudSnippetEntry` (`409` when the trigger is taken) |
| `DELETE /api/snippets/delete` | `{ id }` | any |

### Transcriptions (dictation history)

| Method, path | Request | Response |
| --- | --- | --- |
| `GET /api/transcriptions/list` | snapshot: `limit, before`; delta: `limit, since`; limit 100, no id tie-breaker | `{ transcriptions: CloudTranscription[] }` |
| `POST /api/transcriptions/batch-create` | `{ transcriptions: [{ client_transcription_id, text, raw_text, provider, model, audio_duration_ms, status, created_at }] }` | `{ created: CloudTranscription[] }` |
| `POST /api/transcriptions/create` | one of the above | `CloudTranscription` |
| `POST /api/transcriptions/batch-delete` | `{ ids }` | `{ deleted: string[] }` |

Transcriptions are append-only. There is no update, and a pull only inserts
rows the device does not already have.

### Also called in a full pass, safe to leave unimplemented

`/api/conversations/{create,update,delete,list,messages,search}` (agent chat)
and `/api/analytics/events/{batch,delete}` (Insights counters). Each call is
wrapped in its own try/catch, so a `404` logs an error and the pass continues.

### Not sync: account and team surfaces the fork removed

`/api/workspaces/*`, `/api/teams/*`, `/api/spaces/:id/*`,
`/api/invitations/*`, `/api/me/joinable*`, `/api/notes/:id/share`,
`/api/notes/:id/access`, `/api/v1/keys/*`, `/api/auth/delete-account`,
`/api/notes/search`, `/api/notes/delete-all`. None of these is in scope for
the hub.

## 4. Entities that sync

| Entity | Syncs | Notes |
| --- | --- | --- |
| Spaces | Membership only (read-only mirror of `/api/me/spaces`) | Personal is implicit (`space_id` null). No team spaces exist. |
| Folders | Yes | Name-unique, default-folder adoption |
| Notes | Yes | Optimistic concurrency, conflict banner |
| Dictionary | Yes | |
| Snippets | Yes | |
| Transcriptions | Yes, append-only | First push sends the whole history, in batches of 100 |
| Agent conversations | Upstream only; not an epic entity | |

## 5. How conflicts resolve

- **Order of a pass:** spaces, then folders, notes, conversations,
  transcriptions, dictionary, snippets. Each entity pushes pending creates and
  updates first, then deletes, then pulls. Passes run on start, on focus, on
  reconnect, every 5 minutes, every 30 s while a note is open, and 2 s after
  a local edit (debounced push). Passes are throttled to one per 20 s.
- **Notes: optimistic concurrency.** A PATCH carries `base_updated_at`. When
  the stored row is newer, the server must return `409` with
  `code: note_version_conflict` and the current row in `data.note`. The client
  keeps its edit pending and shows a Keep / Refresh banner. On pull, a newer
  cloud row over a local row with unpushed edits raises the same banner, never
  a silent overwrite. A clean local row takes the cloud copy
  (last-writer-wins on `updated_at`).
- **Folders, dictionary, snippets:** last-writer-wins on normalized
  `updated_at`. A pending (unpushed) folder is never overwritten by a pull.
- **Transcriptions:** no conflicts, because there are no updates.
- **Deletes are soft.** `DELETE` sets `deleted_at` on the server row, which
  must then appear in every other device's delta list as a tombstone. A client
  that sees a tombstone hard-deletes its local copy. A `404` on delete means
  the row is already gone.
- **Server stamps `updated_at`** on every create and update. Delta pulls
  return rows with `updated_at > since` (tie-broken by id where the endpoint
  takes one).
- **Cursors:** notes, folders, and transcriptions store the client's clock at
  the start of the pass as the next `since`. Dictionary and snippets store the
  largest server `updated_at` they saw.

## 6. Recommendation

**Speak the upstream protocol, for the personal-scope subset only.** The hub
implements the 22 endpoints in section 3 for folders, notes, dictionary,
snippets, and transcriptions. It answers `GET /api/me/spaces` with `404`, so
the Mac stays in personal-only mode. The iPhone app speaks the same subset.

Why:

- The Mac already has a 2,700-line sync engine with a tested edge-case
  history: an overwrite fix, conflict banners, orphan cleanup, and cursor
  stall guards. A new protocol would mean writing and proving a new Mac
  sync engine, which is what this design sets out to avoid.
- The server side is small: CRUD over five tables, since-cursor lists that
  include tombstones, server-stamped `updated_at`, and three `409` rules (note
  version, folder name, snippet trigger). That is a normal Postgres service.
- The phone gets a documented contract instead of a new one we design and
  document from scratch.

What speaking it costs on the Mac (a change to the desktop fork):

1. Restore the `cloudApiRequest` preload bridge and its IPC handler. The
   handler factory is still in the tree.
2. Make the hub URL a runtime setting rather than the build-time
   `VITE_OPENWHISPR_API_URL`.
3. Store the device key in `tokenStore` as the bearer, and mark the auth
   context validated without the removed sign-in flow.
4. Open the consent gate (`isSignedIn`, `cloudBackupEnabled`,
   `isSubscribed`). This must bypass the account-scope reconciliation in
   `src/lib/authAccountScope.ts`, whose `purge` path deletes local rows. Every
   local row may have `account_id` NULL, and nothing is backed up yet.

Risks:

- **R1: first sync can lose data.** Item 4 is the data-loss risk. Before
  the first sync, copy the local database and prove against a copy that the
  rewired sign-in path never takes the `purge` branch.
- **R2: clock skew.** Notes and folders cursors use the Mac's clock, while
  the server stamps `updated_at`. If the Mac runs ahead of the hub, a delta
  pull can skip rows. The hub must run NTP, and the desktop round-trip test
  should cover it.
- **R3: dead-code bugs.** The engine is dead code in the fork, so
  upstream-only paths may break at runtime. A desktop round-trip test
  verifies this.

The alternative is a new protocol: a small changes-feed API, with a new
sync module on the Mac and the same module design on the phone. It avoids
reviving auth plumbing, but it replaces a tested engine with an untested one.
It is the better choice only if item 4 proves unsafe.

**Decision (2026-09-29):** use the upstream subset and stay as close to
it as possible. Diverge only where the Swift client or the hub genuinely needs
something different. Record each divergence here, with its reason, when it is
made.
