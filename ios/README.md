# LearnHarness for iOS

A native SwiftUI client for a LearnHarness **cloud server** (see [Cloud server](../docs/cloud-server.md)). The server does the teaching, grading, storage, and view projection. The app renders the server's projected session view, submits learner input, and keeps read-only offline copies.

Requirements: Xcode 27.2 or later. The app targets iOS/iPadOS 27.

## Layout

| Path | Contents |
| --- | --- |
| `LearnHarness.xcodeproj` | App target `LearnHarness` and unit tests `LearnHarnessTests` (folders are file-system synchronized: add files on disk, no project edits needed) |
| `LearnHarness/` | App sources: connection onboarding, session list, transcript |
| `LHKit/` | Local Swift package: `LHAPI` (HTTP, SSE, contract models), `LHCache` (offline copies), `LHRender` (Markdown, LaTeX, web cards) |
| `Config/` | `Base.xcconfig`, `Local.example.xcconfig`, and the Debug-only ATS exception |
| `scripts/vendor-web.sh` | Copies `mermaid.min.js` from `node_modules` into `LHRender` |

## First build

1. Install the web dependencies at the repository root, then vendor Mermaid into the package. Without this step Mermaid diagrams render as source code.

   ```bash
   npm ci && ios/scripts/vendor-web.sh
   ```

2. For a device: copy the signing template and fill in your Team ID and a bundle identifier you own. Simulator builds work without it.

   ```bash
   cp ios/Config/Local.example.xcconfig ios/Config/Local.xcconfig
   ```

3. Open `ios/LearnHarness.xcodeproj`, pick the `LearnHarness` scheme, and run.

## Connecting

On first launch, enter the server address (for example `learn.example.com`; `https://` is assumed) and the server's `LH_REMOTE_TOKEN`. The app checks them against the server before saving. The token is stored in the Keychain on this device only. **Sign Out** forgets the token and this server's offline copies.

Release builds require HTTPS. Debug builds also allow plain HTTP to `localhost` and `.local` hosts, so the simulator can reach a server started on the same Mac:

```bash
LH_REMOTE_TOKEN=<43+ characters> LH_DATA_DIR=/tmp/lh-dev-data npm run dev
```

Then connect to `http://localhost:3000`.

## Tests

```bash
cd ios/LHKit && xcodebuild -scheme LHKit-Package -destination 'platform=iOS Simulator,name=iPhone 18 Pro' test
```

```bash
cd ios && xcodebuild -project LearnHarness.xcodeproj -scheme LearnHarness -destination 'platform=iOS Simulator,name=iPhone 18 Pro' test
```

`LHAPITests` decode every file in `tests/fixtures/native/`, the JSON the server's own projection produces (`scripts/export-native-fixtures.ts`). A server contract change that breaks the app fails here.

## How the app talks to the server

- `GET /api/native/chats/:id/stream` is the session wire: `snapshot` → `patch`* → `settled` while a turn runs, or a single `settled` frame when idle. `NativeViewReducer` applies frames. `GET /api/events` signals idle-time changes.
- Answers go to `POST /api/native/chats/:id/answer` as the raw selection; the server shuffles and grades exactly like the web dock.
- Text arrives display-normalized: math is always `$...$` or `$$...$$`. Unanswered questions and unrevealed model solutions are never in the view.
- Uploads (`POST /api/native/uploads`) return server paths that the composer quotes into messages, like desktop attachments.
