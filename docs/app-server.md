# Cirebronx App-Server

`cirebronx` now exposes a first headless app-server mode over WebSocket JSON-RPC 2.0.

## Start

```powershell
zig build run -- --app-server
```

Optional port:

```powershell
zig build run -- --app-server 9241
```

The server listens on:

```text
ws://127.0.0.1:9240
```

## Protocol

- transport: WebSocket
- protocol: JSON-RPC 2.0
- subprotocol: `jsonrpc.2.0`

## Methods

- `status/read`
- `config/read`
- `session/list`
- `session/read`
- `tool/list`
- `tool/call`
- `mcp/list`
- `mcp/call`
- `turn/start`
- `turn/interrupt`

## Notes

- `turn/start` reuses the same provider and tool runtime used by the interactive CLI and TUI.
- `turn/interrupt` is present for compatibility, but this first server cut does not yet support interrupting an in-flight headless turn.
