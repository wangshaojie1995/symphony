ARG ELIXIR_IMAGE=elixir:1.19-otp-28-slim

FROM node:22-bookworm-slim AS codex

ARG CODEX_VERSION=0.172.0
RUN npm install --global "@openai/codex@${CODEX_VERSION}"

FROM ${ELIXIR_IMAGE} AS build

ENV MIX_ENV=prod
WORKDIR /build

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && mix local.hex --force \
    && mix local.rebar --force

COPY elixir/mix.exs elixir/mix.lock ./
COPY elixir/config ./config
RUN mix deps.get --only prod && mix deps.compile

COPY elixir/lib ./lib
COPY elixir/priv ./priv
RUN mix build

FROM ${ELIXIR_IMAGE} AS runtime

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       bubblewrap ca-certificates curl git openssh-client python3 ripgrep \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --gid 10001 symphony \
    && useradd --uid 10001 --gid symphony --create-home --shell /bin/bash symphony \
    && install -d -m 700 -o symphony -g symphony /home/symphony/.codex \
    && install -d -m 755 -o symphony -g symphony /data/logs /data/workspaces

COPY --from=codex /usr/local/bin/node /usr/local/bin/node
COPY --from=codex /usr/local/lib/node_modules/@openai /usr/local/lib/node_modules/@openai
RUN ln -s /usr/local/lib/node_modules/@openai/codex/bin/codex.js /usr/local/bin/codex \
    && codex --version

COPY --from=build /build/bin/symphony /usr/local/bin/symphony

ENV HOME=/home/symphony \
    CODEX_HOME=/home/symphony/.codex \
    SYMPHONY_WORKSPACE_ROOT=/data/workspaces

USER symphony
WORKDIR /home/symphony
EXPOSE 4000

ENTRYPOINT ["symphony"]
CMD ["--logs-root", "/data/logs", "/config/WORKFLOW.md"]
