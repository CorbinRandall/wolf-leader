# Embeddings ON by default: installs fastembed and bakes the CPU model into the
# image so the hub works offline. Build with --build-arg INCLUDE_EMBEDDINGS=0 for
# a deliberately lean, keyword-only image.
#
#   docker build -t wolf-leader .                                    # hub + semantic search + wiki
#   docker build --build-arg INCLUDE_EMBEDDINGS=0 -t wolf-leader .   # keyword-only
#
# The wiki (Fumadocs, Halo theme) is installed and pre-built in its own stage.
# The runtime image keeps node + node_modules so the hub can rebuild the static
# export after saves/howls (ide_storage/wiki_export.py). One container.
FROM node:22-bookworm-slim AS wiki
WORKDIR /app/wiki
ENV NEXT_TELEMETRY_DISABLED=1
COPY wiki/package.json wiki/package-lock.json* ./
RUN npm ci --no-audit --no-fund || npm install --no-audit --no-fund
COPY wiki/ ./
RUN npm run build

FROM python:3.11-slim AS builder

ARG INCLUDE_EMBEDDINGS=1

WORKDIR /app
COPY requirements-core.txt requirements-embeddings.txt ./

# Always install core. Install embedding deps only when requested.
RUN pip install --no-cache-dir --upgrade pip \
    && pip install --no-cache-dir -r requirements-core.txt \
    && if [ "$INCLUDE_EMBEDDINGS" = "1" ]; then \
         pip install --no-cache-dir -r requirements-embeddings.txt; \
       fi

# Pre-download the CPU embedding model so first run works offline.
# Isolated in its own layer so it only rebuilds when the build arg changes.
ENV FASTEMBED_CACHE_PATH=/opt/fastembed-cache
RUN if [ "$INCLUDE_EMBEDDINGS" = "1" ]; then \
      python -c "from fastembed import TextEmbedding; TextEmbedding(model_name='sentence-transformers/all-MiniLM-L6-v2', cache_dir='/opt/fastembed-cache')"; \
    else \
      mkdir -p /opt/fastembed-cache; \
    fi

FROM python:3.11-slim

WORKDIR /app

ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1
ENV FASTEMBED_CACHE_PATH=/opt/fastembed-cache
ENV NEXT_TELEMETRY_DISABLED=1

RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends git ca-certificates tzdata \
    && rm -rf /var/lib/apt/lists/*

# Node runtime for wiki rebuilds (copied from the official image, no apt repo needed).
COPY --from=wiki /usr/local/bin/node /usr/local/bin/node
COPY --from=wiki /usr/local/lib/node_modules /usr/local/lib/node_modules
RUN ln -sf /usr/local/lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm \
    && ln -sf /usr/local/lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx

COPY --from=builder /usr/local/lib/python3.11/site-packages /usr/local/lib/python3.11/site-packages
COPY --from=builder /usr/local/bin /usr/local/bin
COPY --from=builder /opt/fastembed-cache /opt/fastembed-cache

COPY . .
# Wiki with deps + first build; content/docs is regenerated from Postgres at runtime.
COPY --from=wiki /app/wiki /app/wiki

# Windows checkouts may ship CRLF; the shebang line must be clean in the container.
RUN find . -path ./wiki/node_modules -prune -o \( -name '*.sh' -o -name '*.py' \) -type f -print0 \
      | xargs -0 sed -i 's/\r$//' \
    && chmod +x start.sh
CMD ["./start.sh"]
