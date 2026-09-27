# hermes-webui aggregator proxy

## Goal

<!-- DO NOT EDIT THIS SECTION. The goal should not change as this task proceeds. -->

I will build a proxy server that presents itself as a single hermes-webui (https://github.com/nesquena/hermes-webui) server to clients (like hermex: https://github.com/uzairansaruzi/hermex), but internally routes requests to multiple real hermes-webui backend servers, treating each backend as a distinct **project** within the unified interface — though I can switch to presenting them as **profiles** if that proves more feasible during implementation. The proxy will expose the exact same API schema that a hermes-webui client expects — identical endpoints, identical request/response JSON formats, and identical SSE event types — so that hermex or any other hermes-webui client can connect to the proxy without any modifications.

The target backend is selected based on a project identifier carried in the request. The proxy will implement project discovery (listing available backend servers/projects), session isolation per project, and streaming response passthrough with correct SSE framing.

Fill out this doc with plans and key learnings while working towards this goal. In particular, create and update a TODO list (below). Begin by reading the full source code of both hermes-webui and hermex, then documenting all relevant API interfaces — both as served by hermes-webui and as expected by hermex — into a reference document before building the proxy itself.

## TODO list

- [x] Read and document hermes-webui API surface (endpoints, SSE events, response formats)
- [x] Read and document hermex API client (endpoints, SSE event types, response models)
- [x] Create API reference document (`api-reference.md`)
- [x] Create backend configuration format + loader
- [x] Create end-product usage docs and reference (`aggregator-proxy/README.md`)
- [x] Create endpoint redirection diagrams in Mermaid syntax (`endpoint-redirection-diagrams.md`)
- [x] Document how endpoints are redirected based on project_id routing
- [x] Document smart session routing plan (workspace-path, model-provider, profile, last-used, load balancing heuristics)
- [ ] Implement JSON HTTP proxy (non-SSE endpoints)
- [ ] Implement SSE streaming proxy with event passthrough
- [ ] Implement session-scoped routing via project_id annotation
- [ ] Implement smart session routing heuristics
- [ ] Implement `/api/projects` aggregation (merge backend projects with `_backend_project_id`)
- [ ] Implement `/api/sessions` aggregation (scope sessions to active project, annotate with `_backend_project_id`)

## Key learnings

### Architecture

- **hermex** is a Swift iOS/macOS client that talks to a single hermes-webui server via REST + SSE.
- hermex's `APIClient` uses a `baseURL` (single server). The multi-server epic (#15/#16/#17) is in progress but hermex currently resolves a single server per client instance.
- **hermes-webui** is a Python HTTP server (`server.py` using `http.server.ThreadingHTTPServer`) with a single `routes.py` handling all GET/POST routes, and `streaming.py` for SSE event emission.
- The proxy must be a reverse proxy: accept hermex client requests, route to the appropriate backend based on `project_id`, and merge/aggregate responses for list endpoints.

### Backend Selection Strategy

The hermes-webui server has a `project_id` field on sessions (set at session creation via `POST /api/session/new` body or synthesized at line 17877), and on projects (created via `POST /api/projects/create` body). However, hermes-webui does NOT use project_id to route — projects are just organizational groupings within a single server. The proxy uses `project_id` as the routing key:

**Routing hierarchy (checked in order):**
1. **`project_id` in request body** → Direct backend lookup by project_id. Used by: `POST /api/session/new`, `POST /api/projects/create`, `POST /api/projects/rename`, `POST /api/projects/delete`, `POST /api/goal`, `POST /api/background`.
2. **`stream_id` in query params** → Proxy's in-memory `stream_id → backend` table (populated when `POST /api/chat/start` returns a `stream_id`). Used by: `GET /api/chat/stream`, `GET /api/chat/stream/status`, `GET /api/chat/cancel`.
3. **`session_id` in query/body** → Proxy's in-memory `session_id → backend` table (populated from session creation responses and session lookups; probed across backends if cache miss). Used by: all `POST /api/session/*`, `GET /api/session`, `GET /api/chat/start`, `POST /api/chat/steer`, `GET /api/approval/stream`, `GET /api/clarify/stream`, `GET /api/background/status`, file access endpoints, git endpoints, etc.
4. **No routing key** → Smart session routing heuristics (workspace-path, model-provider, profile affinity, last-used, load balancing), then default backend. Used by: `GET /health`, `GET /api/auth/status`, `GET /api/workspaces`, `GET /api/models`, `GET /api/providers`, `GET /api/settings`, `GET /api/personalities`, `GET /api/profiles`, `GET /api/commands`, `GET /api/prompts`, `GET /api/skills`, `GET /api/memory`, `GET /api/crons`, `GET /api/insights`.

**Aggregation endpoints (broadcast to all backends, merge results):**
- `GET /api/sessions` — merge sessions, annotate each with `_backend_project_id`
- `GET /api/sessions/search` — broadcast search query, merge results
- `GET /api/projects` — merge projects, annotate each with `_backend_project_id`

- Each backend server is configured as a "project backend" with a `project_id`, `url`, and optional `auth_token`.
- Sessions created via `POST /api/session/new` with a `project_id` go to that backend.
- `GET /api/sessions` and `GET /api/projects` aggregate across all configured backends.
- For SSE streaming (`/api/chat/stream`), the proxy tracks which backend owns each `stream_id` (registered during `POST /api/chat/start`) and proxies the SSE connection byte-for-byte.
- The `Last-Event-ID` header is forwarded to the backend for journal-based SSE resume. The proxy preserves `id:` event IDs in the SSE stream for this to work.

### SSE Event Types (hermes-webui → hermex)

Emitted by `streaming.py` via `put('event_name', payload)`. Also seen: `context_status`, `compressed`, `state_saved`, `goal` (in addition to `goal_continue`).

| Event | Payload | Description |
|-------|---------|-------------|
| `token` | `{text: string}` | Assistant token chunk |
| `interim_assistant` | `{text: string, already_streamed: bool?}` | Intermediate assistant text |
| `reasoning` | `{text: string}` | Reasoning/thinking content |
| `tool` | `{event_type, name, preview, args, duration, is_error, id, ...}` | Tool call started |
| `tool_complete` | `{event_type, name, preview, args, duration, is_error, ...}` | Tool call completed |
| `title` | `{session_id, title}` | Session title generated |
| `metering` | `{tps, tps_available, estimated, session_id, ...}` | Tokens-per-second stats |
| `done` | `{session, usage, ephemeral?, answer?, terminal_state?, terminal_reason?}` | Run complete (NOT terminal for SSE — does not break the loop) |
| `stream_end` | `{session_id}` | Stream ended (closes SSE) |
| `cancel` | `{message, type: "cancelled", status: "cancelled", session?, session_id?}` | Run cancelled |
| `error` | `{error: string}` | Error (closes SSE) |
| `apperror` | `{message, type, hint, details?}` | Application-level error (closes SSE) |
| `approval` | ApprovalPendingResponse payload | Approval requested |
| `clarify` | ClarificationPendingResponse payload | Clarification requested |
| `initial` | `{pending?, pending_count?}` | Initial approval/clarify state |
| `pending_steer_leftover` | `{text: string}` | Steer leftover text |
| `compressing` | compression status payload | Context compression starting |
| `compressed` | compression result payload | Context compression completed |
| `runtime_model` | `{model, provider, base_url?}` | Runtime model resolved |
| `warning` | `{type, message}` | Non-fatal warning |
| `goal_continue` | `{session_id, continuation_prompt, text, message, ...}` | Goal continuation |
| `goal` | `{session_id, ...}` | Goal action update |
| `title_status` | `{session_id, status, reason, title, ...}` | Title generation status |
| `context_status` | context status payload | Context status update |
| `state_saved` | `{session_id, ...}` | Session state persisted |
| `initial` | `{pending?, pending_count?}` | Approval/clarify initial state |

**Terminal events** (from `SSE_RELAY_CLOSE_EVENTS` in `run_journal.py`): `stream_end`, `cancel`, `apperror`, `error` — these close the SSE stream. Note: `done` is NOT terminal for SSE — it signals run completion but does NOT break the write loop. `stream_end` (emitted after `done`) is what actually closes the connection.

### Key Request/Response Formats

**POST `/api/chat/start`** → `_handle_chat_start()` → `_start_run()` → `_start_chat_stream_for_session()` (routes.py:23879)

The handler creates a `stream_id` via `uuid.uuid4().hex` (line 23976), registers it in `STREAMS` dict, calls `register_stream_owner(stream_id, s.session_id)` (line 24030), and starts a background thread. Returns (filtered by `_chat_start_response_from_run_start` at line 24094):

```json
{"stream_id": "abc123", "session_id": "...", "pending_started_at": 123.0, "turn_id": "...", "title": "...", "effective_model": "...", "effective_model_provider": "..."}
```

**GET `/api/chat/stream?stream_id=<id>`** → `_handle_sse_stream()` (routes.py:19391)

SSE stream with `Last-Event-ID` / `id:` header for resume. Query params: `stream_id`, `after_seq`, `after_event_id`, `replay`. The resume cursor resolution is in `_chat_stream_resume_cursor()` (routes.py:18869). Journaled events emit `id:` via `_sse_with_id()` (streaming.py:8691). Terminal events in `SSE_RELAY_CLOSE_EVENTS` break the SSE write loop.

**POST `/api/session/new`** → `handle_post` /api/session/new (routes.py:15902)

Accepts `project_id` in body (line 16035: `project_id=body.get("project_id") or None`). Returns:
```json
{"session": {public_session_projection(s.compact() | {"messages": s.messages})}, "worktree_skipped": "..."?}
```

The session projection comes from `s.compact()` (models.py:1985) through `public_session_projection()` (helpers.py:1593), which applies `redact_session_data()`. Contains fields: session_id, title, workspace, model, model_provider, message_count, created_at, updated_at, last_message_at, pinned, archived, project_id, profile, input_tokens, output_tokens, estimated_cost, active_stream_id, is_cli_session, source_tag, etc.

**GET `/api/sessions`** → `_session_list_payload_to_response()` (routes.py:2660)

Each session row is `_sidebar_session_response_item()` (routes.py:11198), filtered to `_SIDEBAR_SESSION_RESPONSE_FIELDS` (route_session_list_cache.py:47). Response:
```json
{"sessions": [...], "sidebar_reference_sessions": [...], "cli_count": N, "archived_count": N, "archived_webui_count": N, "archived_cli_count": N, "include_archived": bool, "all_profiles": bool, "active_profile": "...", "other_profile_count": N, "server_time": 123.0, "server_tz": "+0000"}
```

**GET `/api/projects`** → `load_projects()` (models.py:7246, reads PROJECTS_FILE) (routes.py:14684)

Each project: `project_id` (12-char hex UUID), `name`, `color`, `profile`, `created_at`. Response:
```json
{"projects": [...], "all_profiles": bool, "active_profile": "...", "other_profile_count": N}
```

**GET `/api/session`** → Returns `{"session": {full session detail}}` (line 13954)

### SSE Stream Headers (verified from hermex SSEClient.swift)

hermex's `SSEClient` sends: `Accept: text/event-stream`, `Cache-Control: no-cache, no-transform`, `Accept-Encoding: identity`. Uses `Last-Event-ID` for reconnect/resume (via LDSwiftEventSource library). The `chatStreamURL` method supports `replayAfterSeq` param which maps to `after_seq` query param.

### hermex Client Expectations

- `SessionsResponse`: `{sessions, cliCount, archivedCount, serverTime, serverTz}` — all decoded with lossy/optional methods
- `SessionSummary`: `{sessionId, title, workspace, model, modelProvider, messageCount, createdAt, updatedAt, lastMessageAt, pinned, archived, projectId, profile, inputTokens, outputTokens, estimatedCost, activeStreamId, isCliSession, ...}` — all fields optional, decoded with lossy methods
- `SessionDetail`: full session with messages, toolCalls, compression fields, etc. — decoded with lossy methods for all fields
- `ProjectSummary`: `{projectId, name, color, createdAt}` — all fields optional, lossy decode
- `ChatStartResponse`: `{streamId, sessionId, pendingStartedAt, error}` — all fields optional, lossy decode
- `ChatCancelResponse`: `{ok, cancelled, streamId, error}` — all fields optional, lossy decode
- `ChatStreamStatusResponse`: `{active, streamId, replayAvailable, journal?}` where journal has `terminal` and `terminalState`
- `SSE`: hermex uses `LDSwiftEventSource` library. Sends `Accept: text/event-stream`, `Cache-Control: no-cache, no-transform`, `Accept-Encoding: identity`. Uses `Last-Event-ID` for reconnect/resume. Supports `replay=1` + `after_seq` params via `chatStreamURL(streamID:replayAfterSeq:)`.
- Events decoded by hermex: `token`, `interim_assistant`, `reasoning`, `tool`, `tool_complete`, `title`, `metering`, `done`, `streamEnd`, `cancelled`, `error`, `approvalPending`, `clarificationPending`, `pendingSteerLeftover`

### Project Routing Discovery

Key finding: hermes-webui assigns `project_id` on session creation (routes.py:16035) and on project creation (routes.py:17877: `uuid.uuid4().hex[:12]`). The server does NOT use `project_id` for routing — it's purely organizational. The proxy introduces `project_id` as the routing key from the backend configuration, NOT from the session/project's internal `project_id` field.

**Important:** hermex's `NewSessionRequest` only sends `workspace`, `model`, `modelProvider`, `profile` — it does NOT include `project_id`. The proxy must inject `project_id` based on the client's selected backend context when forwarding `POST /api/session/new`.
