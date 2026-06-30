# Lean by default (keyword-only). Build with --build-arg INCLUDE_EMBEDDINGS=1
# to install the optional embedding deps AND bake the CPU model into the image.
#
#   docker build -t wolf-leader .                              # lean / keyword-only
#   docker build --build-arg INCLUDE_EMBEDDINGS=1 -t wolf-leader .   # + semantic search
FROM python:3.11-slim AS builder

ARG INCLUDE_EMBEDDINGS=0

WORKDIR /app
COPY requirements-core.txt requirements-embeddings.txt ./

# Always install core. Install embedding deps only when requested.
RUN pip install --no-cache-dir --upgrade pip \
    && pip install --no-cache-dir -r requirements-core.txt \
    && if [ "$INCLUDE_EMBEDDINGS" = "1" ]; then \
         pip install --no-cache-dir -r requirements-embeddings.txt; \
       fi

# Pre-download the CPU embedding model so first run works offline (Pi-friendly).
# Isolated in its own layer so it only rebuilds when the build arg changes, not
# on every code/requirements edit. Skipped entirely for the lean image.
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

COPY --from=builder /usr/local/lib/python3.11/site-packages /usr/local/lib/python3.11/site-packages
COPY --from=builder /usr/local/bin /usr/local/bin
COPY --from=builder /opt/fastembed-cache /opt/fastembed-cache

COPY . .

RUN chmod +x start.sh
CMD ["./start.sh"]
