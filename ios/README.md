# LearnHarness for iOS

A native SwiftUI client for a LearnHarness **cloud server** (see [Cloud server](../docs/cloud-server.md)). The server does the teaching, grading, storage, and view projection. The app renders the server's projected session view, submits learner input, and keeps read-only offline copies. It has no data of its own: everything you see lives on the server you connect to, separate from the desktop app's local data.

Requirements: Xcode 27.2 or later. The app runs on iPhone and iPad with iOS/iPadOS 27.

## What the app does

| Tab | Contents |
| --- | --- |
| **Sessions** | Session list (a split view on iPad); new teaching and practice sessions, practice material picked from the graph; rename and delete; the session page with streaming replies, question and problem docks, plan, background-job cards, per-session model and thinking level, and Markdown export through the share sheet |
| **Graph** | The knowledge graph drawn from the server's layout: pinch, pan, double-tap zoom, search, node details with supporting and derived chains and their source sessions (opening the exact passage). Chains & sources manages folders, renames, moves, and deletes. **Extract files…** imports notes (Markdown, text, PDF; files or a folder) from Files. With **Graph rendering** off in Settings, the tab opens on the chains view instead of the canvas |
| **Settings** | Providers (API keys, custom endpoint and its model limits, GitHub Copilot and Grok sign-in, Claude Code, Deepgram and search keys), Models (the three slots, compaction, cache retention), Tools, Graph, Prompts, Dictation, and Server (address and sign out) |

The composer also takes **attachments** and **dictation**:

- **Attachments.** The paperclip uploads photos (converted to JPEG unless PNG or GIF) or files, up to 25 MB each, to the server's uploads folder. The message carries the server path, as on the desktop.
- **Dictation.** The microphone uses Apple's on-device speech recognition by default, with live words. **Settings → Dictation** switches to Deepgram, which uses the server's Deepgram key and inserts the transcript when you stop. The engine choice is stored on the device; the Deepgram language is the server's setting.

Settings are the server's settings. A change made in the app applies to the browser and every other client of the same server, and the reverse.

**Offline.** When the server cannot be reached, the app shows the session list, every session you have opened, and the graph from the last copies it saved, read-only. Sending, answering, imports, and settings need the server.

## First build

1. Install the web dependencies at the repository root, then vendor Mermaid into the package. Without this step Mermaid diagrams render as source code.

   ```bash
   npm ci && ios/scripts/vendor-web.sh
   ```

2. Open `ios/LearnHarness.xcodeproj`, pick the `LearnHarness` scheme and a simulator, and run. Simulator builds need no signing setup.

## Installing on your iPhone or iPad

1. Copy the signing template and fill in your Team ID and a bundle identifier you own (the template says where to find the Team ID):

   ```bash
   cp ios/Config/Local.example.xcconfig ios/Config/Local.xcconfig
   ```

   `Local.xcconfig` is git-ignored. Xcode → Settings → Accounts must be signed in to the same Apple account.
2. Connect the device, or pair it over the network, and turn on **Developer Mode** on it (Settings → Privacy & Security) when iOS asks.
3. Select the device in Xcode and run.
4. With a free Apple account, trust the developer on the device the first time (Settings → General → VPN & Device Management). Apps signed this way stop opening after seven days; run from Xcode again to reinstall. A paid developer membership lasts a year.

The device needs to reach your server over HTTPS (see [Cloud server](../docs/cloud-server.md)); Release builds refuse plain HTTP.

## Connecting

On first launch, enter the server address (for example `learn.example.com`; `https://` is assumed) and the server's `LH_REMOTE_TOKEN`. The app checks them against the server before saving. The token is stored in the Keychain on this device only. **Settings → Server → Sign Out** forgets the token and this server's offline copies.

Debug builds also allow plain HTTP to `localhost` and `.local` hosts, so the simulator can reach a server started on the same Mac:

```bash
LH_REMOTE_TOKEN=<43+ characters> LH_DATA_DIR=/tmp/lh-dev-data npm run dev
```

Then connect to `http://localhost:3000`. Use a scratch data directory as shown, not your real data.

## Permissions

The app asks once for the **microphone** and **speech recognition** when you first dictate. Photos and Files use the system pickers, which need no permission; the app sees only what you pick.

## Layout

| Path | Contents |
| --- | --- |
| `LearnHarness.xcodeproj` | App target `LearnHarness` and unit tests `LearnHarnessTests` (folders are file-system synchronized: add files on disk, no project edits needed) |
| `LearnHarness/App` | App model, tabs, server event hub |
| `LearnHarness/Connection` | Onboarding and Keychain token storage |
| `LearnHarness/Sessions` | Session list, new session, session page, docks, cards |
| `LearnHarness/Graph` | Graph canvas, node details, chains & sources, notes import |
| `LearnHarness/Settings` | The Settings tab |
| `LearnHarness/Input` | Attachments and dictation engines |
| `LHKit/` | Local Swift package: `LHAPI` (HTTP, SSE, contract models, settings, graph geometry), `LHCache` (offline copies), `LHRender` (Markdown, LaTeX, web cards) |
| `Config/` | `Base.xcconfig`, `Local.example.xcconfig`, and the Debug-only ATS exception |
| `scripts/vendor-web.sh` | Copies `mermaid.min.js` from `node_modules` into `LHRender` |

## Tests

```bash
cd ios/LHKit && xcodebuild -scheme LHKit-Package -destination 'platform=iOS Simulator,name=iPhone 18 Pro' test
```

```bash
cd ios && xcodebuild -project LearnHarness.xcodeproj -scheme LearnHarness -destination 'platform=iOS Simulator,name=iPhone 18 Pro' test
```

`LHAPITests` decode every file in `tests/fixtures/native/`, the JSON the server's own projection produces (`scripts/export-native-fixtures.ts`). A server contract change that breaks the app fails here. The package tests run on a simulator; `swift test` on macOS does not build `LHCache`.

## How the app talks to the server

- `GET /api/native/chats/:id/stream` is the session wire: `snapshot` → `patch`* → `settled` while a turn runs, or a single `settled` frame when idle. `NativeViewReducer` applies frames. `GET /api/events` signals idle-time changes (sessions, sources, extraction runs, subscriptions).
- Answers go to `POST /api/native/chats/:id/answer` as the raw selection; the server shuffles and grades exactly like the web dock.
- Text arrives display-normalized: math is always `$...$` or `$$...$$`. Unanswered questions and unrevealed model solutions are never in the view.
- Uploads (`POST /api/native/uploads`) return server paths that the composer quotes into messages, like desktop attachments.
- The graph, notes import, and Settings use the same routes as the web app (`/api/graph/*`, `/api/settings/*`, `/api/keys`, `/api/custom-provider`, `/api/subscriptions`, `/api/claude-code`). Settings writes replace one whole section and keep fields the app does not edit. The subscription, Claude Code, and custom-endpoint controls send the server's own origin in `Origin`, as a same-origin browser would. A subscription sign-in page opens in an in-app Safari sheet after the device code is copied.
