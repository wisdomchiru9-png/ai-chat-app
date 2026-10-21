# AI Chat — Flutter client

Cross-platform client for the AI Chat backend: JWT auth, streaming chat, and a
model benchmarking dashboard.

## Features

- Register / sign in with JWT bearer tokens, persisted across restarts
- Multi-turn chat with replies streamed token by token over SSE
- Session management, scoped to the signed-in user
- Sentiment badges with confidence, long-press to copy, clear conversation
- Analytics dashboard ranking models on quality, cost and latency (`fl_chart`)
- Design system in `theme.dart` (spacing, radius, motion, elevation, semantics)

## Running

```bash
flutter pub get
flutter run                 # Android / iOS device or emulator
flutter run -d chrome       # Web
```

The API base URL defaults to `http://10.0.2.2:8000`, which is how an Android
emulator reaches the host machine. On web, desktop, or a physical device, use the
settings button in the app bar to point it at `http://localhost:8000` or your
deployed backend.

Building with plugins (e.g. `shared_preferences`) requires symlink support on
Windows — enable Developer Mode under Settings → System → For developers.

## Structure

| File | Purpose |
|---|---|
| `lib/main.dart` | App shell, auth gate, session list, streaming chat screen |
| `lib/auth.dart` | Login / register screens, token storage, auth API |
| `lib/analytics_screen.dart` | Model benchmarking dashboard |
| `lib/theme.dart` | Design tokens and Material 3 light/dark themes |

## Tests

```bash
flutter analyze
flutter test
```

See the [root README](../README.md) for backend setup and the full API reference.
