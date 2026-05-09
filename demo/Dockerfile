FROM python:3.14-slim

WORKDIR /app

RUN pip install --no-cache-dir \
    "fastapi>=0.117" \
    "uvicorn[standard]>=0.34" \
    "httpx>=0.28" \
    "pyyaml>=6.0.2"

COPY main.py /app/main.py
COPY dashboard/ /app/dashboard/
COPY registry.demo.yml /app/registry.demo.yml

EXPOSE 8088

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8088"]
