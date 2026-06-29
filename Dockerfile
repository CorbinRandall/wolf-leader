FROM python:3.11-slim AS builder

WORKDIR /app
COPY requirements.txt ./
RUN pip install --no-cache-dir --upgrade pip \
    && pip install --no-cache-dir -r requirements.txt

# Pre-download the CPU embedding model so first run works offline (Pi-friendly).
ENV FASTEMBED_CACHE_PATH=/opt/fastembed-cache
RUN python -c "from fastembed import TextEmbedding; TextEmbedding(model_name='sentence-transformers/all-MiniLM-L6-v2', cache_dir='/opt/fastembed-cache')"

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
