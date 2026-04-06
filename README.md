# cirebronx

`cirebronx` is a Zig terminal coding agent inspired by Claude Code style workflows, with both a plain CLI and a pane-based TUI.

Open-source home: `https://github.com/mexyusef/cirebronx`

## Status

This project is experimental and under active restructuring. It is useful for local testing, but the tool surface, provider adapters, and interaction model may change quickly.

## Highlights

- Interactive REPL, one-shot prompt mode, and `--tui` interface
- OpenAI-compatible, Gemini-compatible, and Anthropic provider paths
- Tool loop with file, grep, shell, and edit operations
- Local skills, plugin manifest discovery, MCP registry, and session resume support
- Permission gating for read, write, and shell operations

## Requirements

- Zig `0.15.2`
- A sibling checkout of `ziggy` at `../ziggy`
- Provider credentials through environment variables

## Build And Run

```powershell
zig build test
zig build
zig build run
zig build run -- --tui
zig build run -- "inspect this repo"
```

## Provider Examples

```powershell
$env:CIREBRONX_PROVIDER='gemini'
$env:GEMINI_API_KEY='...'
$env:OPENAI_MODEL='gemini-2.5-flash'
zig build run -- "hello"
```

```powershell
$env:CIREBRONX_PROVIDER='anthropic'
$env:ANTHROPIC_API_KEY='...'
$env:OPENAI_MODEL='claude-sonnet-4-20250514'
zig build run -- "hello"
```

## Helper Launchers

- `run-gemini.bat`
- `run-gemini.ps1`

## Notes

- `--tui` depends on the local `ziggy` checkout because `build.zig` imports `../ziggy/src/ziggy.zig`.
- This repository currently favors local experimentation over stable release packaging.

## Related Repositories

- `ziggy`: terminal UI library used by the TUI mode
- `fmus-zig`: shared utility layer
- `zigsaw`: adjacent agent/runtime work

## License

MIT. See [LICENSE](LICENSE).
