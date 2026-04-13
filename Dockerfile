FROM alpine:3.20
RUN apk add --no-cache restic openssh-client tzdata ca-certificates
WORKDIR /app
COPY scripts/run-restic-backup.sh /app/run-backup.sh
COPY scripts/start-restic-cron.sh /app/start-cron.sh
RUN chmod +x /app/run-backup.sh /app/start-cron.sh
ENTRYPOINT ["/app/start-cron.sh"]
