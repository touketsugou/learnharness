# Cloud server

Run LearnHarness on your own Linux host so the iOS app (and any browser) can use it away from your desktop. This is a **single-user** server: one access token, one data volume, your keys. Its sessions, graph, settings, and keys are separate from the desktop app's local data; nothing syncs between them.

The container runs the same server as the desktop app with **cloud mode** turned on by `LH_REMOTE_TOKEN`:

- Every page and API request needs the token. The iOS app sends it as `Authorization: Bearer <token>`. A browser signs in once at `/login` and gets an HttpOnly, `Secure`, `SameSite=Strict` session cookie derived from the token. Cookie-authenticated writes must come from the same origin.
- Failed browser sign-ins are throttled globally: after 10 failures in 10 minutes, sign-in pauses until the window passes, even for the right token. Bearer requests are not throttled.
- Learner files uploaded from the phone are stored under `/data/uploads/`. On first boot, if you have never saved a file-access preference, the server restricts the agent's file tools to that folder (Settings → Agent → Tools → File access). You can change it later.
- ChatGPT subscription sign-in is unavailable: its sign-in returns to a loopback address on the server, which a phone cannot reach. API keys, custom OpenAI-compatible endpoints, the GitHub Copilot and xAI device-code connections, and the Claude Code CLI work.
- `LH_REMOTE_TOKEN` cannot be combined with the desktop server variables. With a token shorter than 43 characters or containing spaces, the server fails to start its app: every request returns 500, the reason is in the container log, and the health check reports unhealthy.

## Requirements

- A Linux host with Docker Engine and the Compose plugin. Build on the host itself so native modules match its CPU (x86_64 or arm64).
- A domain name and an HTTPS reverse proxy on the same host. The container listens on `127.0.0.1:3000` only. The proxy **must preserve the `Host` header** (Caddy does by default; with nginx set `proxy_set_header Host $host;`) and must not buffer server-sent events.
- About 3 GB of disk for the image, plus your data.

## Deploy

1. Get the code on the host (your fork, at the branch you want):

   ```bash
   git clone https://github.com/<you>/learnharness.git && cd learnharness
   ```

2. Create the access token and keep a copy somewhere safe, such as a password manager. You will paste it into the iOS app and the browser sign-in page.

   ```bash
   printf 'LH_REMOTE_TOKEN=%s\n' "$(openssl rand -base64 32 | tr '+/' '-_' | tr -d '=')" > .env && chmod 600 .env
   ```

   `.env` is ignored by git and by the Docker build context.

3. Build and start:

   ```bash
   docker compose up -d --build
   ```

   The build runs the same payload gates as a desktop release (`next build`, provider runtime check, standalone payload check, and a boot smoke test). The first build takes several minutes.

4. Put HTTPS in front. A minimal Caddy site:

   ```
   learn.example.com {
   	reverse_proxy 127.0.0.1:3000 {
   		flush_interval -1
   	}
   }
   ```

5. Check it from the host:

   ```bash
   set -a && . ./.env && set +a && node scripts/smoke-remote.mjs http://127.0.0.1:3000
   ```

   It verifies the token gate, sign-in, the native API, and that ChatGPT is unavailable. It creates and deletes one throwaway session and records one failed sign-in.

6. Open `https://learn.example.com`, sign in with the token, and choose your models and keys in Settings. Then add the server address and token in the iOS app.

## Keys and providers

Add provider and search keys in **Settings → Providers**, from the browser or the iOS app. They are stored in `/data/auth.json` inside the data volume. You can instead pass keys as container environment variables in `docker-compose.yml`; environment values override saved keys.

### Claude Code CLI

The image includes a pinned Claude Code CLI (build argument `CLAUDE_CODE_VERSION`). Sign it in once inside the container. Its credentials live in the `lh-claude` volume and survive restarts:

```bash
docker compose exec -it learnharness claude
```

Complete the sign-in, quit the CLI, then enable it in **Settings → Providers → External CLI**. See [Claude Code](claude-code.md) for what the CLI controls and how billing works.

## Data and backups

| Volume | Contents |
| --- | --- |
| `lh-data` → `/data` | sessions, graph, jobs, settings, prompt overrides, uploads, `auth.json` (keys) |
| `lh-claude` → `/home/node/.claude` | Claude Code CLI sign-in and settings |

Run **one** container per data volume. The stores are plain files with in-process locking, so two servers on the same volume corrupt each other's writes.

Back up while the server is stopped:

```bash
docker compose stop
docker run --rm -v learnharness_lh-data:/data -v "$PWD":/backup busybox tar czf /backup/lh-data.tgz -C /data .
docker compose start
```

The volume name is prefixed with the Compose project name, which defaults to the folder name. Check it with `docker volume ls`. The backup includes your API keys, so store it like a password.

## Updating

```bash
git pull && docker compose up -d --build
```

Data formats are versioned; a newer server reads older records. Back up before major updates.

## Rotating the token

Replace the value in `.env` and run `docker compose up -d`. Every browser session and every device signed in with the old token is signed out immediately.

## Demos and visuals

Demo checks use the container's Chromium (`CHROME_PATH=/usr/bin/chromium`, headless, no sandbox inside the container). Visuals and PDFs render natively without it.

## Troubleshooting

- **Every request returns 500:** run `docker compose logs learnharness`. An `LH_REMOTE_TOKEN` error means the token is too short, contains spaces, or is combined with the desktop variables. Fix `.env` and run `docker compose up -d`.
- **Browser writes fail with 403 "Cross-origin request refused":** the reverse proxy is rewriting `Host`. Preserve it.
- **The iOS app connects but live replies arrive only at the end:** the proxy is buffering server-sent events. Disable response buffering for the site.
- **Sign-in says "Too many failed attempts":** wait up to 10 minutes; the throttle is global by design.
