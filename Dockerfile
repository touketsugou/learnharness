# LearnHarness cloud server (single user, LH_REMOTE_TOKEN): see docs/cloud-server.md.
# One container = one server process = one data volume. Never run replicas
# against the same volume: the stores are plain files with in-process locking.

# ── build: next build (standalone) + the same payload gates as desktop:dist ──
FROM node:26-bookworm AS build
WORKDIR /app
# The server never runs Electron; skip its ~100 MB binary download.
ENV ELECTRON_SKIP_BINARY_DOWNLOAD=1 \
	NEXT_TELEMETRY_DISABLED=1
COPY package.json package-lock.json ./
RUN npm ci
COPY . .
RUN npx next build \
	&& node scripts/smoke-provider-runtime.mjs \
	&& node scripts/build-server.mjs \
	&& node scripts/smoke-server.mjs

# ── runtime ──────────────────────────────────────────────────────────────────
FROM node:26-bookworm-slim
# chromium: demo checks (headless fallback; the desktop's Electron helper is
# absent here). Noto CJK + emoji: readable demo/visual renders. tini: signals.
RUN apt-get update \
	&& apt-get install -y --no-install-recommends chromium fonts-noto-cjk fonts-noto-color-emoji ca-certificates tini \
	&& rm -rf /var/lib/apt/lists/*
# Optional external CLI provider (Settings → Providers → External CLI).
# Pinned; LearnHarness requires >= 2.1.259 (src/core/contracts/claude-code.ts).
ARG CLAUDE_CODE_VERSION=2.1.311
RUN npm install -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" && npm cache clean --force

ENV NODE_ENV=production \
	NEXT_TELEMETRY_DISABLED=1 \
	HOSTNAME=0.0.0.0 \
	PORT=3000 \
	LH_DATA_DIR=/data \
	LH_AUTH_FILE=/data/auth.json \
	CHROME_PATH=/usr/bin/chromium \
	CLAUDE_CONFIG_DIR=/home/node/.claude

WORKDIR /app
COPY --from=build --chown=node:node /app/.next/standalone ./
RUN mkdir -p /data /home/node/.claude && chown node:node /data /home/node/.claude
USER node
VOLUME ["/data", "/home/node/.claude"]
EXPOSE 3000
# /login is the one page served without credentials in cloud mode.
HEALTHCHECK --interval=30s --timeout=5s --start-period=40s --retries=3 \
	CMD node -e "fetch('http://127.0.0.1:3000/login').then((r) => process.exit(r.ok ? 0 : 1), () => process.exit(1))"
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["node", "server.js"]
