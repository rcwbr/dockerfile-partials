# API Reference: hermes-webui ↔ hermex

## Overview

hermex (iOS/macOS client) communicates with a hermes-webui server via REST JSON endpoints + SSE streaming. The proxy presents itself as a single hermes-webui server and routes requests to multiple backends based on `project_id`, `session_id`, or `stream_id`.

## hermes-webui API Endpoints

### GET Endpoints

| Method | Path | Response Type | Description |
|--------|------|---------------|-------------|
| GET | `/health` | HealthResponse | Health check (aggregated by proxy) |
| GET | `/api/auth/status` | AuthStatusResponse | Auth status |
| GET | `/api/sessions` | SessionsResponse | List sessions (aggregate) |
| GET | `/api/sessions/search?q=...&content=1&depth=N` | SessionSearchResponse | Search sessions (broadcast) |
| GET | `/api/sessions?include_archived=1&archived_limit=N&archived_offset=N` | SessionsResponse | List sessions with archived |
| GET | `/api/session?session_id=<id>&messages=0\|1&msg_limit=N&msg_before=N&expand_renderable=1` | SessionResponse | Session detail |
| GET | `/api/session/status?session_id=<id>` | SessionStatusResponse | Session running status |
| GET | `/api/session/yolo?session_id=<id>` | SessionYoloResponse | YOLO mode status |
| GET | `/api/projects` | ProjectsResponse | List projects (aggregate) |
| GET | `/api/workspaces` | WorkspacesResponse | List workspaces |
| GET | `/api/workspaces/suggest?prefix=...` | WorkspaceSuggestions | Workspace suggestions |
| GET | `/api/models` | ModelsResponse | Model catalog |
| GET | `/api/models/live` | LiveModelsResponse | Live model validation |
| GET | `/api/model/auxiliary` | AuxiliaryModelsResponse | Auxiliary models |
| GET | `/api/providers` | ProvidersResponse | Provider status |
| GET | `/api/provider/quota?provider=<id>&refresh=1` | ProviderQuotaResponse | Provider quota |
| GET | `/api/settings` | SettingsResponse | Saved settings |
| GET | `/api/personalities` | PersonalitiesResponse | List personalities |
| GET | `/api/profiles` | ProfilesResponse | List profiles |
| GET | `/api/default-model` | DefaultModelResponse | Default model |
| GET | `/api/reasoning?model=...&provider=...` | ReasoningConfigResponse | Reasoning config |
| GET | `/api/commands` | CommandsResponse | Agent commands |
| GET | `/api/prompts` | PromptsResponse | Saved prompts |
| GET | `/api/updates/check` | UpdatesCheckResponse | Update check |
| GET | `/api/insights?days=N` | InsightsResponse | Usage insights |
| GET | `/api/crons` | CronsResponse | List cron jobs |
| GET | `/api/crons/status?job_id=<id>` | CronStatusResponse | Cron status |
| GET | `/api/crons/history?job_id=<id>&offset=N&limit=N` | CronHistoryResponse | Cron run history |
| GET | `/api/crons/output?job_id=<id>&limit=N` | CronOutputResponse | Cron output |
| GET | `/api/crons/recent` | RecentCronsResponse | Recent cron runs |
| GET | `/api/crons/delivery-options` | CronDeliveryOptionsResponse | Cron delivery options |
| GET | `/api/memory` | MemoryResponse | Memory entries |
| GET | `/api/skills` | SkillsResponse | List skills |
| GET | `/api/skills/content?name=<id>&file=<path>` | SkillContentResponse | Skill content |
| GET | `/api/list?session_id=<id>&path=<path>` | DirectoryListingResponse | List directory |
| GET | `/api/file?session_id=<id>&path=<path>` | FileResponse | Read file |
| GET | `/api/file/raw?session_id=<id>&path=<path>` | RawFileResponse | Raw file content |
| GET | `/api/media?session_id=<id>&path=<path>` | MediaResponse | Read media |
| GET | `/api/git-info?session_id=<id>` | GitInfoResponse | Git repository info |
| GET | `/api/git/status?session_id=<id>` | GitStatusResponse | Git status |
| GET | `/api/git/branches?session_id=<id>` | GitBranchesResponse | Git branches |
| GET | `/api/git/diff?session_id=<id>&path=<path>&kind=<kind>` | GitDiffResponse | Git diff |
| GET | `/api/chat/stream?stream_id=<id>` | SSE stream | Chat stream (SSE) |
| GET | `/api/chat/stream/status?stream_id=<id>` | ChatStreamStatusResponse | Stream status |
| GET | `/api/chat/cancel?stream_id=<id>` | ChatCancelResponse | Cancel stream |
| GET | `/api/approval/pending?session_id=<id>` | ApprovalPendingResponse | Pending approvals |
| GET | `/api/approval/stream?session_id=<id>` | SSE stream | Approval stream (SSE) |
| GET | `/api/clarify/pending?session_id=<id>` | ClarificationPendingResponse | Pending clarifications |
| GET | `/api/clarify/stream?session_id=<id>` | SSE stream | Clarify stream (SSE) |
| GET | `/api/background/status?session_id=<id>` | BackgroundStatusResponse | Background task status |
| GET | `/api/session/export?session_id=<id>&format=<fmt>` | ExportedSessionResponse | Export session |
| GET | `/api/session/stream?session_id=<id>` | SSE stream | Session events stream (SSE) |
| GET | `/api/terminal/output?stream_id=<id>` | SSE stream | Terminal output stream (SSE) |

### POST Endpoints

| Method | Path | Request Body | Response Type | Description |
|--------|------|-------------|---------------|-------------|
| POST | `/api/chat/start` | ChatStartRequest | ChatStartResponse | Start a chat turn |
| POST | `/api/chat/steer` | ChatSteerRequest | ChatSteerResponse | Steer active stream |
| POST | `/api/goal` | GoalSubmissionRequest | GoalSubmissionResponse | Submit goal |
| POST | `/api/btw` | BtwRequest | BtwStartResponse | Start side question |
| POST | `/api/background` | BackgroundRequest | BackgroundStartResponse | Start background task |
| POST | `/api/session/new` | SessionNewRequest | SessionNewResponse | Create new session |
| POST | `/api/session/rename` | {session_id, title} | SessionMutationResponse | Rename session |
| POST | `/api/session/delete` | {session_id} | OkResponse | Delete session |
| POST | `/api/session/pin` | {session_id, pinned} | SessionMutationResponse | Pin/unpin session |
| POST | `/api/session/archive` | {session_id, archived} | SessionMutationResponse | Archive session |
| POST | `/api/session/branch` | {session_id, ...} | BranchResponse | Fork session |
| POST | `/api/session/duplicate` | {session_id} | SessionNewResponse | Duplicate session |
| POST | `/api/session/compress` | {session_id, ...} | SessionCompressResponse | Compress session |
| POST | `/api/session/clear` | {session_id} | OkResponse | Clear session |
| POST | `/api/session/undo` | {session_id} | SessionUndoResponse | Undo last message |
| POST | `/api/session/retry` | {session_id} | SessionRetryResponse | Retry last turn |
| POST | `/api/session/truncate` | {session_id} | OkResponse | Truncate session |
| POST | `/api/session/update` | UpdateSessionRequest | SessionNewResponse | Update session |
| POST | `/api/session/yolo` | {session_id, yolo} | SessionYoloResponse | Set YOLO mode |
| POST | `/api/session/move` | {session_id, target_profile} | SessionMutationResponse | Move session |
| POST | `/api/session/compression-recovery/start` | {session_id} | CompressionRecoveryResponse | Start compression recovery |
| POST | `/api/projects/create` | {name, color?, profile?} | ProjectMutationResponse | Create project |
| POST | `/api/projects/rename` | {project_id, name, color?} | ProjectMutationResponse | Rename project |
| POST | `/api/projects/delete` | {project_id} | ProjectMutationResponse | Delete project |
| POST | `/api/approval/respond` | ApprovalRespondRequest | ApprovalRespondResponse | Respond to approval |
| POST | `/api/clarify/respond` | ClarificationRespondRequest | ClarificationRespondResponse | Respond to clarification |
| POST | `/api/file/save` | FileSaveRequest | OkResponse | Save file |
| POST | `/api/file/delete` | {session_id, path} | OkResponse | Delete file |
| POST | `/api/file/create` | FileCreateRequest | OkResponse | Create file |
| POST | `/api/git/commit` | GitCommitRequest | GitCommitResponse | Commit changes |
| POST | `/api/git/stage` | {session_id, path} | OkResponse | Stage file |
| POST | `/api/providers` | {provider, api_key} | ProviderUpdateResponse | Set provider key |
| POST | `/api/updates/apply` | ApplyUpdateRequest | UpdateApplyResponse | Apply updates |
| POST | `/api/settings` | SettingsBody | SettingsResponse | Save settings |
| POST | `/api/skills` | SkillRequest | OkResponse | Install/update skill |
| POST | `/api/profile/switch` | {profile} | ProfileSwitchResponse | Switch profile |

### PUT Endpoints

| Method | Path | Request Body | Response Type | Description |
|--------|------|-------------|---------------|-------------|
| PUT | `/api/file` | FileUpdateRequest | OkResponse | Update file |

### DELETE Endpoints

| Method | Path | Query/Body | Response Type | Description |
|--------|------|-----------|---------------|-------------|
| DELETE | `/api/skills` | ?name=<id> | OkResponse | Delete skill |

---

## Request/Response Schemas

### ChatStartRequest

**hermex sends:**
```json
{
  "session_id": "string",
  "message": "string",
  "workspace": "string?",      // optional, hermex sends if provided
  "model": "string?",           // optional
  "model_provider": "string?",  // optional
  "profile": "string?",         // optional
  "explicit_model_pick": true,  // optional, omitted when false
  "attachments": [              // optional
    {
      "name": "string",
      "path": "string",
      "mime": "string",
      "size": int,
      "is_image": bool
    }
  ]
}
```

> **Note:** hermex does NOT send `project_id` in `ChatStartRequest`. The session lookup by `session_id` is what the proxy uses to route to the correct backend.

### ChatStartResponse

**hermes-webui returns** (via `_chat_start_response_from_run_start`):
```json
{
  "stream_id": "string",
  "session_id": "string",
  "pending_started_at": 1234567890.0,
  "turn_id": "string?",        // present if journal event was created
  "title": "string?",          // session title
  "effective_model": "string?",// present when normalized_model is True
  "effective_model_provider": "string?" // present when model_provider is set
}
```

hermex decodes (`ChatStartResponse`): `streamId`, `sessionId`, `pendingStartedAt`, `error`. All fields optional. Extra fields are ignored.

**Error response** (409, session in use or profile mismatch):
```json
{
  "error": "string",
  "code": "string?",           // e.g. "session_profile_mismatch"
  "active_stream_id": "string?", // on "session already has an active stream"
  "session_id": "string?",     // on profile mismatch
  "profile": "string?"        // on profile mismatch
}
```

### SessionNewRequest

**hermes-webui accepts** (from `handle_post` at line 15902):
```json
{
  "workspace": "string?",
  "model": "string?",
  "model_provider": "string?",
  "profile": "string?",
  "project_id": "string?",          // Used for backend routing by the proxy
  "prev_session_id": "string?",
  "worktree": true,                 // Three-value: explicit true/false/null
  "enabled_toolsets": ["string"],
  "prompt": "string?",
  "mood": "string?",
  "enabled_toolsets": ["string"]
}
```

> **Note:** hermex's `NewSessionRequest` only sends `workspace`, `model`, `modelProvider`, `profile` — it does NOT send `project_id`. The proxy must inject `project_id` based on the client's selected backend context.

### SessionNewResponse

**hermes-webui returns:**
```json
{
  "session": {
    "session_id": "string",
    "title": "string",
    "workspace": "string",
    "model": "string",
    "model_provider": "string?",
    "message_count": 0,
    "created_at": 1234567890.0,
    "updated_at": 1234567890.0,
    "last_message_at": 1234567890.0,
    "pinned": false,
    "archived": false,
    "project_id": "a1b2c3d4e5f6?",    // backend's internal project_id (12-char hex), NOT the proxy routing key
    "profile": "string?",
    "input_tokens": 0,
    "output_tokens": 0,
    "estimated_cost": 0.0,
    "cache_read_tokens": 0,
    "cache_write_tokens": 0,
    "personality": "string?",
    "active_stream_id": "string?",
    "is_cli_session": false,
    "source_tag": "string?",
    "session_source": "string?",
    "worktree_path": "string?",     // only when worktree is used
    "enabled_toolsets": ["string?"],
    // ... plus many more fields from compact()
  },
  "worktree_skipped": "string?"  // present when config-default worktree was skipped
}
```

### SessionsResponse (GET /api/sessions)

**hermes-webui returns:**
```json
{
  "sessions": [...],               // array of session summary dicts
  "sidebar_reference_sessions": [...], // optional, reference sessions
  "cli_count": 0,
  "archived_count": 5,
  "archived_webui_count": 0,       // added in newer versions
  "archived_cli_count": 0,         // added in newer versions
  "include_archived": false,
  "all_profiles": false,
  "active_profile": "default",
  "other_profile_count": 0,
  "server_time": 1234567890.0,
  "server_tz": "+0000",
  "webui_session_count": 0         // present when key exists in payload
}
```

hermex decodes (`SessionsResponse`): `sessions` (→ `[SessionSummary]`), `cliCount`, `archivedCount`, `serverTime`, `serverTz`. All fields use lossy/optional decoding.

**SessionSummary fields (hermex):** `sessionId`, `title`, `workspace`, `model`, `modelProvider`, `messageCount`, `createdAt`, `updatedAt`, `lastMessageAt`, `pinned`, `archived`, `projectId`, `profile`, `inputTokens`, `outputTokens`, `estimatedCost`, `activeStreamId`, `isStreaming`, `isCliSession`, `userMessageCount`, `hasPendingUserMessage`, `pendingStartedAt`, `worktreePath`, `sourceTag`, `rawSource`, `sessionSource`, `sourceLabel`, `parentSessionId`, `relationshipType`, `readOnly`, `isReadOnly`, `matchType`, `matchPreview`.

### ProjectsResponse (GET /api/projects)

**hermes-webui returns:**
```json
{
  "projects": [
    {
      "project_id": "string",       // 12-char hex UUID
      "name": "string",
      "color": "string?",           // hex color like "#3B82F6"
      "profile": "string",          // profile tag (since #1614)
      "created_at": 1234567890.0
    }
  ],
  "all_profiles": false,
  "active_profile": "default",
  "other_profile_count": 0
}
```

hermex decodes (`ProjectsResponse`): `projects` (→ `[ProjectSummary]`). `ProjectSummary` decodes: `projectId`, `name`, `color`, `createdAt`. All fields optional.

### SSE /api/chat/stream

**Query params:** `stream_id=<id>`, `after_seq=N` (optional, for journal replay), `after_event_id=<id>` (optional), `replay=1` (when resume requested)

> **Resume protocol precedence** (verified at `routes.py:18869`): explicit query params (`after_seq`, `after_event_id`) take precedence over the `Last-Event-ID` header. The proxy must NOT rewrite or synthesize these — pass them all through as-is.

**Headers (sent by hermex):**
- `Accept: text/event-stream`
- `Cache-Control: no-cache, no-transform`
- `Accept-Encoding: identity`
- `Last-Event-ID: <id>` (on reconnect for resume — spec-compliant SSE auto-sends this)

**Event format:**
```
event: <event_type>\n
data: <json>\n
id: <event_id>\n  (for journaled/resumable events)
\n
```

hermex uses `LDSwiftEventSource` library (based on the spec-compliant `EventSource` protocol). It automatically:
- Sends `Last-Event-ID` on reconnect
- Parses `event:`, `data:`, and `id:` fields
- Dispatches events by event name

### SSE Resume Protocol

The proxy must forward these resume signals to the backend:
1. `Last-Event-ID` header → forwarded as-is
2. `after_seq` query param → forwarded as-is (takes precedence over the header)
3. `after_event_id` query param → forwarded as-is
4. `replay=1` query param → forwarded as-is

All `id:`, `event:`, and `data:` lines must be passed through byte-for-byte without modification. The proxy must NOT interpret or rewrite SSE lines.

### SSE Event Types (hermes-webui → hermex)

Emitted by `streaming.py` via `put('event_name', payload)` → serialized to SSE by `_sse()` or `_sse_with_id()`:

| Event | Terminal? | Description |
|-------|-----------|-------------|
| `token` | No | Assistant token chunk `{text}` |
| `interim_assistant` | No | Intermediate assistant text `{text, already_streamed?}` |
| `reasoning` | No | Reasoning/thinking content `{text}` |
| `tool` | No | Tool call started `{event_type?, name?, preview?, args?, duration?, is_error?, id, ...}` |
| `tool_complete` | No | Tool call completed `{event_type?, name?, preview?, args?, duration?, is_error?, ...}` |
| `title` | No | Session title generated `{session_id?, title?}` |
| `metering` | No | Tokens-per-second stats `{tps, tps_available, estimated, session_id, ...}` |
| `done` | Yes* | Run complete `{session, usage, ephemeral?, answer?, terminal_state?, terminal_reason?}` |
| `stream_end` | Yes | Stream ended `{session_id}` — closes SSE |
| `cancel` | Yes | Run cancelled `{message, type: "cancelled", status: "cancelled", session?, session_id?}` |
| `error` | Yes | Error `{error}` — closes SSE |
| `apperror` | Yes | App error `{message, type, hint, details?}` — closes SSE |
| `approval` | No | Approval requested — ApprovalPendingResponse payload |
| `clarify` | No | Clarification requested — ClarificationPendingResponse payload |
| `initial` | No | Initial approval/clarify state `{pending?, pending_count?}` |
| `pending_steer_leftover` | No | Steer leftover text `{text}` |
| `compressing` | No | Context compression starting |
| `runtime_model` | No | Runtime model resolved `{model, provider, base_url?}` |
| `warning` | No | Non-fatal warning `{type, message}` |
| `goal_continue` | No | Goal continuation `{session_id, continuation_prompt, text, message, ...}` |
| `goal` | No | Goal action update `{session_id, ...}` |
| `title_status` | No | Title generation status `{session_id, status, reason, title, ...}` |
| `context_status` | No | Context status update |
| `compressed` | No | Context compression completed |
| `state_saved` | No | Session state persisted |

> *`done` is terminal for the agent run but may not close the SSE stream immediately — `stream_end` or a terminal event is what actually breaks the SSE write loop (checked via `SSE_RELAY_CLOSE_EVENTS`).

hermex decodes (`SSEClient.swift`) these event names: `token`, `interim_assistant`, `reasoning`, `tool`, `tool_complete`, `title`, `metering`, `done`, `streamEnd`, `cancelled`, `error`, `approvalPending`, `clarificationPending`, `pendingSteerLeftover`.

---

## Server-Side Functions (Implementation Notes)

- `POST /api/chat/start` → `_handle_chat_start()` → `_start_run()` → `_start_chat_stream_for_session()`
  - Creates a `stream_id` (UUID hex, `uuid.uuid4().hex`)
  - Registers stream in `STREAMS` dict (thread-safe via `STREAMS_LOCK`)
  - Calls `register_stream_owner(stream_id, s.session_id)` to link stream→session
  - Starts a background thread (`_run_agent_streaming` or `_run_gateway_chat_streaming`)
  - Returns `{"stream_id": "...", "session_id": "...", "pending_started_at": ..., "turn_id": ..., "title": ..., "effective_model": ..., "effective_model_provider": ...}`
  - Response filtered through `_chat_start_response_from_run_start()` to expose only legacy browser-facing fields

- `GET /api/chat/stream?stream_id=<id>` → `_handle_sse_stream()`
  - Subscribes to the stream's `SessionChannel`
  - Replays journal events on reconnect (via `Last-Event-ID` / `after_seq` / `_sse_replay_run_journal_gap_checked`)
  - Emits SSE events with `id:` for journaled events (via `_sse_with_id`)
  - Break loop on terminal events in `SSE_RELAY_CLOSE_EVENTS`
  - Socket write timeout via `_sse_set_write_deadline` (default 20s, env tunable)

- `GET /api/chat/stream/status?stream_id=<id>` → checks `STREAMS` registry
  - Returns `{"active": bool, "stream_id": "...", "replay_available": bool, "journal": RunJournalStatus?}`
  - 404 if stream not found and no journal summary

- `GET /api/chat/cancel?stream_id=<id>` → cancels the stream
  - Returns `{"ok": true, "cancelled": true, "stream_id": "..."}`

- `POST /api/session/new` → creates session with `project_id` from body (line 16035)
  - Returns `{"session": {...full session projection...}, "worktree_skipped": "..."?}`

- `GET /api/sessions` → `_session_list_payload_to_response()` with sidebar-scoped rows
  - Each row is `_sidebar_session_response_item()` — filters to `_SIDEBAR_SESSION_RESPONSE_FIELDS`
  - Response includes `sessions`, `cli_count`, `archived_count`, `archived_webui_count`, `archived_cli_count`, `include_archived`, `all_profiles`, `active_profile`, `other_profile_count`, `server_time`, `server_tz`

- `GET /api/projects` → `load_projects()` — reads from `PROJECTS_FILE` (JSON)
  - Each project: `project_id` (12-char hex), `name`, `color`, `profile`, `created_at`
  - Profile-scoped by default; `?all_profiles=1` returns all
