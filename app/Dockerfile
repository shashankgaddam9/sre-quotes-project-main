# ---- Stage 1: install dependencies ----
FROM python:3.12-slim AS builder
WORKDIR /build
COPY requirements.txt .
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

# ---- Stage 2: small runtime image ----
FROM python:3.12-slim
ARG APP_VERSION=dev
ENV APP_VERSION=${APP_VERSION} \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

# Run as a non-root user (security best practice; K8s securityContext enforces it too)
RUN useradd --create-home --uid 10001 appuser
WORKDIR /app
COPY --from=builder /install /usr/local
COPY main.py .
COPY static ./static
USER 10001

EXPOSE 8080
# gunicorn = production WSGI server. 1 worker x 8 threads per pod.
# Why 1 worker? Each worker process keeps its own Prometheus counters, so with N workers
# every scrape sees a different worker and graphs jump around. We scale with more PODS
# instead (that's the Kubernetes way). (Alternative: prometheus_client multiprocess mode.)
CMD ["gunicorn", "--bind", "0.0.0.0:8080", "--workers", "1", "--threads", "8", \
     "--timeout", "30", "--graceful-timeout", "20", "--access-logfile", "-", "main:app"]
