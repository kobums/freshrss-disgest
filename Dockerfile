# freshrss-digest — 새로 들어온 글을 claude -p 로 요약해 Notion 에 쌓는 배치 스크립트.
# 요약 엔진인 Claude Code CLI(구독)를 포함한다.
# 구독 인증(~/.claude)은 이미지에 굽지 않고 런타임에 볼륨 마운트한다.
FROM node:20-slim

# python3(스크립트 실행) + ca-certificates(HTTPS) 만 추가로 필요.
RUN apt-get update \
 && apt-get install -y --no-install-recommends python3 ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# Claude Code CLI 설치 (요약은 구독 사용량 → 토큰당 과금 없음)
RUN npm install -g @anthropic-ai/claude-code \
 && npm cache clean --force

WORKDIR /app
COPY summarize_unread.py /app/summarize_unread.py

# seen 파일과 커서 파일(freshrss_digest_state.json)은 마운트 가능한 데이터 디렉터리에 둔다.
ENV SEEN_FILE=/data/freshrss_digest_seen.json
VOLUME ["/data"]

ENTRYPOINT ["python3", "/app/summarize_unread.py"]
