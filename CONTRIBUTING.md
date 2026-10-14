# Contributing

Thanks for helping make GitHub Float better!

## Development

```bash
swift build                      # debug build
./build.sh                       # build and install ~/Applications/GitHubFloat.app
.build/debug/GitHubFloat --dump  # print the board data without opening the UI
```

Source layout (`Sources/GitHubFloat`):

| File | What it does |
|---|---|
| `GitHubClient.swift` | GraphQL query, pagination, token resolution |
| `Model.swift` | Review stages, settings, polling store |
| `Views.swift` | SwiftUI panel |
| `Notifier.swift` | Change detection and macOS notifications |
| `main.swift` | Floating panel, menu bar item, menu, CLI flags |
| `Screenshots.swift` | Renders README screenshots with demo data |

If you change the UI, regenerate the screenshots with `.build/release/GitHubFloat --screenshots docs` (run it from the repo root).

## Pull requests

- Keep PRs small and focused, and describe what changed and why.
- Make sure `swift build -c release` passes.
- Use [Conventional Commits](https://www.conventionalcommits.org) (`feat:`, `fix:`, `docs:`...).
- Never commit tokens or real project data. Use the demo data in `Screenshots.swift`.

## Releasing

Push a tag `vX.Y.Z`. The release workflow builds a universal app and attaches `GitHubFloat.zip` to the GitHub release.
