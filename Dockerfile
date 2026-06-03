# Stage 1: build Symphony escript
FROM hexpm/elixir:1.19.5-erlang-28-debian-bookworm-slim AS builder

WORKDIR /build
COPY elixir/ .
RUN mix deps.get && MIX_ENV=prod mix escript.build

# Stage 2: runtime — reuse the same Erlang/OTP version to keep ERTS compatible with the escript
FROM hexpm/elixir:1.19.5-erlang-28-debian-bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    git \
    nodejs \
    npm \
    && rm -rf /var/lib/apt/lists/*

# Install Codex CLI
RUN npm install -g @openai/codex

COPY --from=builder /build/bin/symphony /usr/local/bin/symphony

VOLUME ["/workspaces", "/app/state", "/root/.codex"]

ENTRYPOINT ["symphony", "--workflow", "/app/WORKFLOW.md"]
