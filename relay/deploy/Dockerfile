# 构建上下文必须是relay 目录；仅复制 relay 源文件，不复制宿主配置或本机数据。
FROM python:3.12-slim
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
RUN groupadd --gid 10001 relay && useradd --uid 10001 --gid 10001 --no-create-home relay \
    && mkdir -p /app/relay /data && chown 10001:10001 /data
WORKDIR /app
COPY store.py server.py /app/relay/
COPY deploy/healthcheck.py /app/healthcheck.py
USER 10001:10001
EXPOSE 18766
ENTRYPOINT ["python", "-m", "relay.server", "--database", "/data/relay.sqlite"]
CMD ["serve", "--host", "0.0.0.0", "--port", "18766"]
