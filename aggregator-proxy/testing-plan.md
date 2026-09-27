# Unit Testing Plan for the Hermes-WebUI Aggregator Proxy

> **Target implementation**: `hermes_webui_aggregator_proxy.py` (Python 3.12, stdlib `http.server`)
> **Test framework**: `unittest` + `unittest.mock` (stdlib only — no external dependencies)
> **Test discovery**: `python -m pytest tests/` or `python -m unittest discover tests/`

## Overview

The proxy is a stateless HTTP reverse proxy with two distinct concerns:

1. **Routing** — deciding which backend to send each request to (pure logic, easily testable).
2. **Forwarding** — sending the HTTP request to the backend and returning the response (requires network or mock).

Tests should cover both concerns, prioritizing routing logic (pure functions that can be tested without network) over forwarding mechanics (which require HTTP mocks).

## Test Architecture

### Backend mock: `MockBackend`

A lightweight in-process HTTP server (using `http.server.HTTPServer` + `ThreadingMixIn`) that:

- Listens on an ephemeral port (port 0).
- Records all received requests (method, path, headers, body) in a `received` list.
- Returns configurable responses per endpoint.
- Optionally injects delays to test timeout behavior.

Each test gets fresh `MockBackend` instances for each backend (alpha, beta, gamma).

### Proxy fixture: `ProxyHarness`

Wraps the proxy server instance with:

- A pre-configured `backends.json` pointing to mock backend URLs.
- An ephemeral port.
- Helper methods: `post(path, body=...)`, `get(path)`, `sse(path, timeout=5)`.
- Access to routing tables (`stream_id → backend`, `session_id → backend`).

## Test Categories

### 1. Routing Key Resolution (`test_routing.py`)

Pure logic tests — no HTTP involved. Tests the routing hierarchy:

| Test | Description |
|------|-------------|
| `test_project_id_routing` | `POST /api/session/new` with `{"project_id": "alpha"}` → routes to alpha backend |
| `test_stream_id_routing` | `GET /api/chat/stream?stream_id=...` → routes to backend recorded during `POST /api/chat/start` |
| `test_session_id_routing` | `POST /api/chat/steer` with `{"session_id": "abc123"}` → routes to backend owning that session |
| `test_session_id_cache_lookup` | After session creation, `GET /api/session?session_id=...` → routes to cached backend |
| `test_session_id_cache_miss_broadcast` | Unknown session_id → broadcast to all backends, route based on which responds with the session |
| `test_project_id_on_project_create` | `POST /api/projects/create` with `{"project_id": "beta"}` → routes to beta backend |

### 2. Smart Session Routing Heuristics (`test_smart_routing.py`)

Tests the fallback routing when no `project_id`, `stream_id`, or `session_id` is present:

| Test | Description |
|------|-------------|
| `test_workspace_path_affinity` | `POST /api/session/new` with `{"workspace": "/Users/eric/ml"}` → routes to backend whose `workspace_roots` includes that path |
| `test_model_provider_affinity` | `POST /api/session/new` with `{"model": "claude-3.5-sonnet", "model_provider": "anthropic"}` → routes to backend whose `providers` list matches |
| `test_profile_affinity` | `POST /api/session/new` with `{"profile": "work"}` → routes to backend whose `profiles` list includes "work" |
| `test_last_used_session_affinity` | After a session is created on backend A, the next `POST /api/session/new` without project_id → routes to backend A (last-used heuristic) |
| `test_load_balancing_round_robin` | With no matching heuristics, consecutive new sessions → round-robin across backends (when `load_balancer: "round-robin"` configured) |
| `test_load_balancing_least_sessions` | With `load_balancer: "least-sessions"`, new session → routes to backend with fewest active sessions (when `load_balancer: "least-sessions"` configured) |
| `test_default_backend_fallback` | When no heuristics match and no backends are configured for smart routing → routes to default backend |

### 3. Aggregation Endpoints (`test_aggregation.py`)

Tests broadcast + merge logic:

| Test | Description |
|------|-------------|
| `test_projects_aggregation` | `GET /api/projects` → broadcasts to all backends, merges results, annotates each with `_backend_project_id` |
| `test_sessions_aggregation` | `GET /api/sessions` → broadcasts to all backends, merges sessions, annotates with `_backend_project_id` |
| `test_sessions_search_aggregation` | `GET /api/sessions/search?q=...` → broadcasts search to all backends, merges results |
| `test_projects_aggregation_one_backend_down` | When one backend is unreachable → returns results from healthy backends, logs error |
| `test_sessions_aggregation_empty_backend` | When a backend returns empty sessions → still annotated correctly |

### 4. SSE Streaming Forward (`test_sse_streaming.py`)

Tests byte-for-byte passthrough:

| Test | Description |
|------|-------------|
| `test_sse_event_passthrough` | `GET /api/chat/stream?stream_id=...` → SSE events forwarded line-by-line without modification |
| `test_sse_last_event_id_forwarded` | On reconnect, `Last-Event-ID` header → forwarded to backend for journal replay |
| `test_sse_after_seq_forwarded` | On reconnect, `after_seq=N` query param → forwarded to backend |
| `test_sse_replay_param_forwarded` | `replay=1` query param → forwarded to backend |
| `test_sse_relay_close_on_stream_end` | When backend emits `stream_end` event → proxy closes the SSE stream |
| `test_sse_relay_close_on_cancel` | When backend emits `cancel` event → proxy closes the SSE stream |
| `test_sse_relay_close_on_apperror` | When backend emits `apperror` event → proxy closes the SSE stream |
| `test_sse_relay_does_not_close_on_done` | When backend emits `done` event → proxy keeps SSE stream open (done is NOT terminal) |
| `test_sse_chunked_encoding` | SSE events chunked correctly to client (each `data:`, `event:`, `id:` line preserved) |

### 5. HTTP Forwarding Mechanics (`test_http_forwarding.py`)

Tests that requests/responses are correctly proxied:

| Test | Description |
|------|-------------|
| `test_post_body_forwarded` | `POST /api/session/new` body → forwarded verbatim to backend |
| `test_post_response_returned` | Backend response → returned verbatim to client |
| `test_get_query_params_forwarded` | GET query params → forwarded to backend |
| `test_auth_token_forwarded` | `Authorization: Bearer <token>` header → set from `backends[].auth_token` |
| `test_content_type_forwarded` | `Content-Type` and `Accept` headers → forwarded |
| `test_non_sse_500_propagates` | Backend returns 500 → proxy returns 500 to client |
| `test_non_sse_503_propagates` | Backend returns 503 → proxy returns 503 to client |

### 6. Error Handling (`test_errors.py`)

| Test | Description |
|------|-------------|
| `test_backend_unreachable_502` | When backend is down → proxy returns 502 |
| `test_no_backends_503` | When no backends configured → proxy returns 503 |
| `test_session_new_no_project_creates_session` | `POST /api/session/new` without `project_id` → session still created on smart-selected backend |
| `test_sse_stream_unknown_stream_id_404` | `GET /api/chat/stream?stream_id=unknown` → returns 404 or error event |

### 7. Routing Table Integrity (`test_routing_tables.py`)

| Test | Description |
|------|-------------|
| `test_stream_id_table_populated_on_chat_start` | After `POST /api/chat/start` returns `stream_id`, the proxy records `stream_id → backend` |
| `test_session_id_table_populated_on_session_new` | After `POST /api/session/new` returns `session_id`, the proxy records `session_id → backend` |
| `test_session_id_table_populated_on_sessions_list` | After `GET /api/sessions`, session_id mappings are populated from results |
| `test_session_id_lookup_after_cache_miss` | Unknown session_id → broadcast probe → backend found → table populated |

## Test Patterns

### Pattern 1: Routing Logic Unit Tests (no HTTP)

```python
class TestRoutingKeys(unittest.TestCase):
    def setUp(self):
        self.proxy = ProxyHarness()

    def test_project_id_in_body_routes_directly(self):
        request = {"method": "POST", "path": "/api/session/new",
                   "body": {"project_id": "alpha", "workspace": "/code"}}
        backend = self.proxy.resolve_backend(request)
        assert backend.project_id == "alpha"
```

These test the `resolve_backend()` function directly — no HTTP server needed.

### Pattern 2: Mock Backend Integration Tests

```python
class TestMockBackend(unittest.TestCase):
    def setUp(self):
        self.backends = [MockBackend() for _ in range(3)]
        self.proxy = ProxyHarness(backends=self.backends)

    def test_projects_aggregation(self):
        self.backends[0].set_response("/api/projects",
                                       {"projects": [{"project_id": "a1b2", "name": "A"}]})
        self.backends[1].set_response("/api/projects",
                                       {"projects": [{"project_id": "c3d4", "name": "B"}]})
        response = self.proxy.get("/api/projects")
        projects = response.json()["projects"]
        assert len(projects) == 2
        assert projects[0]["_backend_project_id"] == self.backends[0].project_id
```

### Pattern 3: SSE Passthrough Tests

```python
class TestSSEPassthrough(unittest.TestCase):
    def setUp(self):
        self.backend = MockBackend(sse_events=[
            "event: initial\ndata: {}\n\n",
            "event: token\ndata: hello\n\n",
            "event: done\ndata: {}\n\n",
            "event: stream_end\ndata: {}\n\n",
        ])
        self.proxy = ProxyHarness(backends=[self.backend])

    def test_done_does_not_close_stream(self):
        # Start a session + chat/start to get a stream_id
        session = self.proxy.post("/api/session/new", body={})
        self.proxy.post("/api/chat/start", body={"session_id": session["session_id"]})
        events = list(self.proxy.sse("GET /api/chat/stream?stream_id=..."))
        assert "done" in events  # stream should still be open after done
        assert "stream_end" in events  # stream closes at stream_end
```

## MockBackend Implementation Sketch

```python
class MockBackend(threading.Thread):
    """In-process HTTP server that records requests and returns canned responses."""

    def __init__(self, project_id: str, port: int = 0):
        self.project_id = project_id
        self.server = HTTPServer(("127.0.0.1", port), self._make_handler())
        self.actual_port = self.server.server_address[1]
        self.received = []  # list of (method, path, headers, body)
        self.responses = {}  # path -> (status, headers, body) or callable
        self.sse_events = []  # for streaming endpoints
        self.delay_ms = 0  # artificial latency

    def set_response(self, path, status=200, body=None, headers=None):
        self.responses[path] = (status, headers or {}, body)

    def run(self):
        self.server.serve_forever()

    def shutdown(self):
        self.server.shutdown()
```

## Running the Tests

```bash
# Unit tests only (fast, no network)
python -m pytest tests/test_routing.py tests/test_smart_routing.py tests/test_routing_tables.py -v

# Full suite (includes mock backend integration)
python -m pytest tests/ -v

# SSE streaming tests
python -m pytest tests/test_sse_streaming.py -v

# With coverage
python -m pytest tests/ --cov=hermes_webui_aggregator_proxy
```

## Test Data Conventions

### Backend config for tests:

```json
{
  "backends": [
    {"project_id": "alpha", "url": "http://127.0.0.1:PORT_A", "name": "Alpha"},
    {"project_id": "beta", "url": "http://127.0.0.1:PORT_B", "name": "Beta",
     "workspace_roots": ["/Users/eric/ml"], "providers": ["anthropic/claude-3.5-sonnet"]},
    {"project_id": "gamma", "url": "http://127.0.0.1:PORT_C", "name": "Gamma", "profiles": ["work"]}
  ],
  "default_backend": "alpha",
  "load_balancer": "round-robin"
}
```

### Mock backend responses (matching hermes-webui schemas):

- `POST /api/session/new` → `{"session": {"session_id": "abc123", "project_id": "a1b2c3d4e5f6", ...}}`
- `POST /api/chat/start` → `{"stream_id": "str_abc123", "session_id": "abc123", "turn_id": "t1", ...}`
- `GET /api/projects` → `{"projects": [{"project_id": "a1b2c3d4e5f6", "name": "My Project", ...}], ...}`
- `GET /api/sessions` → `{"sessions": [{"session_id": "abc123", ...}], ...}`
- `GET /api/chat/stream` → SSE stream (newline-delimited events)

## Open Questions

1. **SSE test timing**: SSE streams are long-lived. Tests must use timeouts and event counts to avoid hanging. Consider limiting `sse_events` to a finite set per mock.
2. **Concurrency**: Some tests (session_id cache miss → broadcast) involve concurrent requests. Need to decide whether to test concurrency or mock it out.
3. **Configuration validation tests**: Should there be tests for invalid `backends.json`? (e.g., missing `url`, bad `project_id` format, duplicate project_ids.)
