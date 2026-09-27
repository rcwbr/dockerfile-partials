# Endpoint Redirection Diagrams

This document visualizes how hermex API requests flow through the aggregator proxy to individual hermes-webui backend servers, based on `project_id` routing. All diagrams use [Mermaid](https://mermaid.js.org/) syntax.

---

## High-Level Architecture

```mermaid
graph LR
    subgraph Client
        C[hermex client]
    end

    subgraph Proxy
        P[Aggregator Proxy<br/>listens on :8080]
        RT[Routing Table<br/>session_id → backend<br/>stream_id → backend<br/>project_id → backend]
        RH[Request Handler<br/>1. Parse routing key<br/>2. Select backend<br/>3. Forward request<br/>4. Return/aggregate response]
    end

    subgraph Backends
        BA[Backend A<br/>project_id: alpha<br/>:8081]
        BB[Backend B<br/>project_id: beta<br/>:8082]
        BC[Backend C<br/>project_id: gamma<br/>:8083]
    end

    C --> P
    P --> RT
    RT --> RH
    RH -- "alpha" --> BA
    RH -- "beta" --> BB
    RH -- "gamma" --> BC
    RH -- "default" --> BA
```

---

## Routing Decision Flow

```mermaid
flowchart TD
    Start[hermex request → Proxy] --> CheckAgg{Is aggregation<br/>endpoint?}

    CheckAgg -- Yes --> Broadcast[Broadcast to all backends]
    Broadcast --> Merge[Merge responses]
    Merge --> Annotate[Annotate each entry<br/>with _backend_project_id]
    Annotate --> ReturnAgg[Return merged response]

    CheckAgg -- No --> CheckRouting{Has routing key?}

    CheckRouting -- "project_id<br/>in body" --> PRoute[Route to<br/>backend by config project_id]
    CheckRouting -- "session_id<br/>in body/query" --> SLookup[Look up<br/>session_id → backend]
    CheckRouting -- "stream_id<br/>in query" --> FLookup[Look up<br/>stream_id → backend]
    CheckRouting -- No routing key --> Default[Route to<br/>default backend]

    SLookup --> SCache[Cache mapping]
    SLookup --> SRoute[Route to<br/>owning backend]

    FLookup --> FRoute[Route to<br/>owning backend]

    PRoute --> Forward[Forward request<br/>to selected backend]
    SRoute --> Forward
    FRoute --> Forward
    Default --> Forward

    Forward --> ReturnResp[Return response<br/>or SSE passthrough]
    ReturnAgg --> End[hermex client]
    ReturnResp --> End
```

---

## Project Creation & Management

```mermaid
sequenceDiagram
    participant Client as hermex client
    participant Proxy as Aggregator Proxy
    participant B as Backend B (beta)

    Client->>Proxy: POST /api/projects/create
    Note right of Client: { project_id: "beta", name: "ML Research" }
    Proxy->>Proxy: Parse routing key
    Note right of Proxy: project_id = "beta"
    Proxy->>B: POST /api/projects/create
    Note left of B: { name: "ML Research" }<br/>(project_id stripped or passed through)
    B-->>Proxy: { ok: true, ... }
    Proxy-->>Client: { ok: true, ... }
```

---

## Session Creation (Project Selection)

```mermaid
sequenceDiagram
    participant Client as hermex client
    participant Proxy as Aggregator Proxy
    participant BC as Backend C (gamma)

    Client->>Proxy: POST /api/session/new
    Note right of Client: { project_id: "gamma", model: "gpt-4" }
    Proxy->>Proxy: Parse routing key
    Note right of Proxy: project_id = "gamma"
    Proxy->>BC: POST /api/session/new
    Note left of BC: { model: "gpt-4" }
    BC-->>Proxy: { session_id: "sess_gam_abc", ... }
    Proxy->>Proxy: Record: session_id → Backend C
    Proxy-->>Client: { session: { session_id: "sess_gam_abc", project_id: "c3d4e5f6a7b8", ... } }
```

---

## Session Listing (Aggregation)

```mermaid
sequenceDiagram
    participant Client as hermex client
    participant Proxy as Aggregator Proxy
    participant BA as Backend A (alpha)
    participant BB as Backend B (beta)
    participant BC as Backend C (gamma)

    Client->>Proxy: GET /api/sessions
    Proxy->>BA: GET /api/sessions
    BA-->>Proxy: { sessions: [...], ... }
    Proxy->>BB: GET /api/sessions
    BB-->>Proxy: { sessions: [...], ... }
    Proxy->>BC: GET /api/sessions
    BC-->>Proxy: { sessions: [...], ... }
    Proxy->>Proxy: Merge all sessions<br/>Annotate: alpha sessions → _backend_project_id: "alpha"<br/>beta sessions → _backend_project_id: "beta"<br/>gamma sessions → _backend_project_id: "gamma"
    Proxy-->>Client: { sessions: [ { _backend_project_id: "alpha", ... }, { _backend_project_id: "gamma", ... }, { _backend_project_id: "beta", ... } ], ... }
```

---

## Opening a Session (Session Lookup)

```mermaid
sequenceDiagram
    participant Client as hermex client
    participant Proxy as Aggregator Proxy
    participant BC as Backend C (gamma)

    Client->>Proxy: GET /api/session?session_id=sess_gam_abc
    Proxy->>Proxy: Parse routing key
    Note right of Proxy: session_id = "sess_gam_abc"
    alt In routing table
        Proxy->>Proxy: Lookup: sess_gam_abc → Backend C
    else Not in table
        Proxy->>Proxy: Probe all backends to find session
        Proxy->>Proxy: Cache mapping
    end
    Proxy->>BC: GET /api/session?session_id=sess_gam_abc
    BC-->>Proxy: { session: { ... } }
    Proxy-->>Client: { session: { ... } }
```

---

## Chat Start (Session → Backend Routing)

```mermaid
sequenceDiagram
    participant Client as hermex client
    participant Proxy as Aggregator Proxy
    participant BC as Backend C (gamma)

    Client->>Proxy: POST /api/chat/start
    Note right of Client: { session_id: "sess_gam_abc", message: "Explain transformers" }
    Proxy->>Proxy: Parse routing key
    Note right of Proxy: session_id = "sess_gam_abc"<br/>→ Backend C (from routing table)
    Proxy->>BC: POST /api/chat/start
    Note left of BC: { session_id: "sess_gam_abc", message: "Explain transformers" }
    BC-->>Proxy: { stream_id: "str_abc123", session_id: "sess_gam_abc", ... }
    Proxy->>Proxy: Record: stream_id "str_abc123" → Backend C
    Proxy-->>Client: { stream_id: "str_abc123", session_id: "sess_gam_abc", ... }
```

---

## Chat Stream SSE (Stream ID → Backend Routing)

```mermaid
sequenceDiagram
    participant Client as hermex client
    participant Proxy as Aggregator Proxy
    participant BC as Backend C (gamma)

    Client->>Proxy: GET /api/chat/stream?stream_id=str_abc123
    Note right of Client: Accept: text/event-stream<br/>Cache-Control: no-cache<br/>Last-Event-ID: evt_5 (on reconnect)<br/>after_seq=5 (optional, explicit cursor)
    Proxy->>Proxy: Parse routing key
    Note right of Proxy: stream_id = "str_abc123"<br/>→ Backend C (from routing table)
    Proxy->>BC: GET /api/chat/stream?stream_id=str_abc123<br/>(forward all SSE headers + query params)
    Note over Proxy,BC: Byte-for-byte SSE passthrough
    BC->>Proxy: event: token\r\ndata: {"text":"Hello"}\r\nid: evt_1\r\n\r\n
    Proxy->>Client: event: token\r\ndata: {"text":"Hello"}\r\nid: evt_1\r\n\r\n
    BC->>Proxy: event: reasoning\r\ndata: {"text":"..."}\r\nid: evt_2\r\n\r\n
    Proxy->>Client: event: reasoning\r\ndata: {"text":"..."}\r\nid: evt_2\r\n\r\n
    BC->>Proxy: event: done\r\ndata: {...}\r\nid: evt_5\r\n\r\n
    Proxy->>Client: event: done\r\ndata: {...}\r\nid: evt_5\r\n\r\n
    BC->>Proxy: event: stream_end\r\ndata: {"session_id":"..."}\r\n\r\n
    Proxy->>Client: event: stream_end\r\ndata: {"session_id":"..."}\r\n\r\n

    Note over Client: On reconnect, client sends<br/>Last-Event-ID: evt_5<br/>Proxy forwards to Backend C for journal replay<br/>(also forwards after_seq/replay=1 if present)
```

---

## Chat Steer (Session → Backend Routing)

```mermaid
sequenceDiagram
    participant Client as hermex client
    participant Proxy as Aggregator Proxy
    participant BA as Backend A (alpha)

    Client->>Proxy: POST /api/chat/steer
    Note right of Client: { session_id: "sess_alp_xyz", text: "Also mention attention" }
    Proxy->>Proxy: Parse routing key
    Note right of Proxy: session_id = "sess_alp_xyz"<br/>→ Backend A (from routing table)
    Proxy->>BA: POST /api/chat/steer
    Note left of BA: { session_id: "sess_alp_xyz", text: "Also mention attention" }
    BA-->>Proxy: { ok: true }
    Proxy-->>Client: { ok: true }
```

---

## Project Listing (Aggregation)

```mermaid
sequenceDiagram
    participant Client as hermex client
    participant Proxy as Aggregator Proxy
    participant BA as Backend A (alpha)
    participant BB as Backend B (beta)
    participant BC as Backend C (gamma)

    Client->>Proxy: GET /api/projects
    Proxy->>BA: GET /api/projects
    BA-->>Proxy: { projects: [...], ... }
    Proxy->>BB: GET /api/projects
    BB-->>Proxy: { projects: [...], ... }
    Proxy->>BC: GET /api/projects
    BC-->>Proxy: { projects: [...], ... }
    Proxy->>Proxy: Merge all projects<br/>Annotate: Backend A → _backend_project_id: "alpha"<br/>Backend B → _backend_project_id: "beta"<br/>Backend C → _backend_project_id: "gamma"
    Proxy-->>Client: { projects: [ { _backend_project_id: "alpha", ... }, { _backend_project_id: "beta", ... }, { _backend_project_id: "gamma", ... } ], ... }
```

---

## Approval / Clarification Streams

```mermaid
sequenceDiagram
    participant Client as hermex client
    participant Proxy as Aggregator Proxy
    participant BC as Backend C (gamma)

    Client->>Proxy: GET /api/approval/stream?session_id=sess_gam_abc
    Note right of Client: Accept: text/event-stream
    Proxy->>Proxy: Parse routing key
    Note right of Proxy: session_id = "sess_gam_abc"<br/>→ Backend C (from routing table)
    Proxy->>BC: GET /api/approval/stream?session_id=sess_gam_abc
    Note over Proxy,BC: Byte-for-byte SSE passthrough
    BC->>Proxy: event: approval\r\ndata: { ApprovalPendingResponse }\r\n\r\n
    Proxy->>Client: event: approval\r\ndata: { ApprovalPendingResponse }\r\n\r\n
```

---

## File Access (Session → Backend Routing)

```mermaid
sequenceDiagram
    participant Client as hermex client
    participant Proxy as Aggregator Proxy
    participant BC as Backend C (gamma)

    Client->>Proxy: GET /api/file?session_id=sess_gam_abc&path=/src/main.py&messages=1
    Proxy->>Proxy: Parse routing key
    Note right of Proxy: session_id = "sess_gam_abc"<br/>→ Backend C (from routing table)
    Proxy->>BC: GET /api/file?session_id=sess_gam_abc&path=/src/main.py&messages=1
    BC-->>Proxy: { file: { ... } }
    Proxy-->>Client: { file: { ... } }
```

---

## Session Search (Aggregation / Broadcast)

```mermaid
sequenceDiagram
    participant Client as hermex client
    participant Proxy as Aggregator Proxy
    participant BA as Backend A (alpha)
    participant BB as Backend B (beta)
    participant BC as Backend C (gamma)

    Client->>Proxy: GET /api/sessions/search?q=transformers&content=1&depth=2
    Proxy->>Proxy: No session_id to route — broadcast to all backends
    Proxy->>BA: GET /api/sessions/search?q=transformers&content=1&depth=2
    BA-->>Proxy: { sessions: [...], ... }
    Proxy->>BB: GET /api/sessions/search?q=transformers&content=1&depth=2
    BB-->>Proxy: { sessions: [...], ... }
    Proxy->>BC: GET /api/sessions/search?q=transformers&content=1&depth=2
    BC-->>Proxy: { sessions: [...], ... }
    Proxy->>Proxy: Merge search results<br/>Annotate each with _backend_project_id
    Proxy-->>Client: { sessions: [ { _backend_project_id: "alpha", ... }, { _backend_project_id: "gamma", ... } ], ... }
```

---

## Routing Key Summary Table

| Endpoint Pattern | Routing Key Extracted From | Fallback |
|---|---|---|
| `POST /api/session/new` | `project_id` (body) or smart heuristics (workspace/model/provider) | default backend (after smart heuristics) |
| `POST /api/projects/create` | `project_id` (body) | default backend |
| `POST /api/projects/rename` | `project_id` (body) | default backend |
| `POST /api/projects/delete` | `project_id` (body) | default backend |
| `POST /api/chat/start` | `session_id` (body) | default backend |
| `POST /api/chat/steer` | `session_id` (body) | default backend |
| `POST /api/goal` | `project_id` (body) or smart heuristics | default backend (after smart heuristics) |
| `POST /api/btw` | `session_id` (body) | default backend |
| `POST /api/background` | `session_id` or `project_id` (body) | default backend |
| `POST /api/session/*` (rename/delete/pin/archive/branch/duplicate/compress/clear/undo/retry/truncate/update/yolo/move) | `session_id` (body) | default backend |
| `POST /api/approval/respond` | `session_id` (body) | default backend |
| `POST /api/clarify/respond` | `session_id` (body) | default backend |
| `POST /api/file/*` (save/delete/create) | `session_id` (body) | default backend |
| `POST /api/git/*` (commit/stage) | `session_id` (body) | default backend |
| `GET /api/session` | `session_id` (query) | default backend |
| `GET /api/session/status` | `session_id` (query) | default backend |
| `GET /api/session/yolo` | `session_id` (query) | default backend |
| `GET /api/session/export` | `session_id` (query) | default backend |
| `GET /api/chat/stream` | `stream_id` (query) | default backend |
| `GET /api/chat/stream/status` | `stream_id` (query) | default backend |
| `GET /api/chat/cancel` | `stream_id` (query) | default backend |
| `GET /api/approval/stream` | `session_id` (query) | default backend |
| `GET /api/clarify/stream` | `session_id` (query) | default backend |
| `GET /api/background/status` | `session_id` (query) | default backend |
| `GET /api/list` | `session_id` (query) | default backend |
| `GET /api/file` | `session_id` (query) | default backend |
| `GET /api/file/raw` | `session_id` (query) | default backend |
| `GET /api/media` | `session_id` (query) | default backend |
| `GET /api/git-info` | `session_id` (query) | default backend |
| `GET /api/git/status` | `session_id` (query) | default backend |
| `GET /api/git/branches` | `session_id` (query) | default backend |
| `GET /api/git/diff` | `session_id` (query) | default backend |
| `GET /api/sessions` | N/A — aggregate all backends | N/A |
| `GET /api/sessions/search` | `query` params — broadcast to all | N/A |
| `GET /api/projects` | N/A — aggregate all backends | N/A |
| `GET /health` | N/A — proxy health | N/A |
| All other `GET`/`POST` | N/A | default backend |
