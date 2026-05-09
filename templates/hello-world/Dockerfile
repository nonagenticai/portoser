FROM alpine:latest

WORKDIR /app

# Add your application here
COPY . .

HEALTHCHECK --interval=30s --timeout=10s --start-period=40s --retries=3 \
  CMD wget --no-verbose --tries=1 --spider http://localhost:8989/health || exit 1

CMD ["sh", "-c", "echo 'Template needs implementation'"]
