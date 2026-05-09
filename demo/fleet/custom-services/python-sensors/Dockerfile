FROM python:3.12-alpine
WORKDIR /app
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt
COPY main.py ./
EXPOSE 8011
HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
    CMD wget -q --spider http://127.0.0.1:8011/health || exit 1
# Port 8011 (not 8000) — portoser's registry validator forbids 8000 (see
# web/backend/services/registry_service.py:FORBIDDEN_PORT).
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8011"]
