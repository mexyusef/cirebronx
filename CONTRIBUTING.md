# Contributing

Contributions should keep behavior explicit and debuggable.

## Development

```powershell
zig build test
zig fmt src build.zig
```

## Guidelines

- Keep provider-specific behavior isolated from the core app flow.
- Do not weaken permission checks for convenience.
- Document new commands, flags, or environment variables in the README.
- Include reproducible steps for protocol, tool, or TUI regressions.
