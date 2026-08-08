ARG KIWI_VERSION=0.23.2

# ---- Builder: Kiwi(https://github.com/bab2min/Kiwi) 기반 한글 형태소 분석
#      커스텀 PGroonga 토크나이저(TokenKiwi) 플러그인만 컴파일 ----
# libgroonga-dev만 있으면 컴파일 가능하므로 postgres 이미지 대신 가벼운 베이스 사용.
# Kiwi는 Linux x86_64용 프리빌드 바이너리+모델을 공식 배포하므로 Kiwi 자체는 소스 빌드하지 않음.
FROM debian:trixie-slim AS kiwi-builder
ARG KIWI_VERSION

RUN apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates wget \
        gcc libc6-dev pkg-config && \
    wget -q https://packages.groonga.org/debian/groonga-apt-source-latest-trixie.deb -O /tmp/groonga-apt-source.deb && \
    apt-get install -y --no-install-recommends /tmp/groonga-apt-source.deb && \
    rm -f /tmp/groonga-apt-source.deb && \
    apt-get update && \
    apt-get install -y --no-install-recommends libgroonga-dev

RUN mkdir -p /opt/kiwi /opt/kiwi-model && \
    cd /tmp && \
    wget -q https://github.com/bab2min/Kiwi/releases/download/v${KIWI_VERSION}/kiwi_lnx_x86_64_v${KIWI_VERSION}.tgz && \
    tar xzf kiwi_lnx_x86_64_v${KIWI_VERSION}.tgz -C /opt/kiwi && \
    rm -f kiwi_lnx_x86_64_v${KIWI_VERSION}.tgz && \
    wget -q https://github.com/bab2min/Kiwi/releases/download/v${KIWI_VERSION}/kiwi_model_v${KIWI_VERSION}_base.tgz && \
    tar xzf kiwi_model_v${KIWI_VERSION}_base.tgz -C /opt/kiwi-model && \
    rm -f kiwi_model_v${KIWI_VERSION}_base.tgz && \
    cp /opt/kiwi/lib/libkiwi.so.${KIWI_VERSION} /usr/local/lib/ && \
    ln -s libkiwi.so.${KIWI_VERSION} /usr/local/lib/libkiwi.so && \
    ldconfig

COPY token_kiwi.c /tmp/token_kiwi.c
RUN mkdir -p /usr/lib/x86_64-linux-gnu/groonga/plugins/tokenizers && \
    gcc -shared -fPIC -O2 -Wall \
        -I/opt/kiwi/include \
        $(pkg-config --cflags groonga) \
        -o /usr/lib/x86_64-linux-gnu/groonga/plugins/tokenizers/kiwi.so \
        /tmp/token_kiwi.c \
        -L/usr/local/lib -lkiwi \
        $(pkg-config --libs groonga)

# ---- 최종 이미지: 빌드 도구(gcc/libgroonga-dev 등) 없이 실행에 필요한 산출물만 포함 ----
FROM postgres:18-trixie
ARG KIWI_VERSION

# 이미지 기본 타임존을 한국시간으로 (tzdata는 베이스 이미지에 이미 포함되어 있음)
ENV TZ=Asia/Seoul
RUN ln -snf /usr/share/zoneinfo/${TZ} /etc/localtime && \
    echo ${TZ} > /etc/timezone

# PostGIS, PGroonga, pg_cron: Debian trixie용 공식 apt 패키지 설치
RUN apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates wget && \
    wget -q https://packages.groonga.org/debian/groonga-apt-source-latest-trixie.deb -O /tmp/groonga-apt-source.deb && \
    apt-get install -y --no-install-recommends /tmp/groonga-apt-source.deb && \
    rm -f /tmp/groonga-apt-source.deb && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        postgresql-18-postgis-3 \
        postgresql-18-postgis-3-scripts \
        postgresql-18-pgdg-pgroonga \
        postgresql-18-cron && \
    apt-get purge -y --auto-remove wget && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# TokenKiwi: 빌더 스테이지에서 컴파일한 플러그인 + Kiwi 런타임 라이브러리/모델만 복사
COPY --from=kiwi-builder \
     /usr/lib/x86_64-linux-gnu/groonga/plugins/tokenizers/kiwi.so \
     /usr/lib/x86_64-linux-gnu/groonga/plugins/tokenizers/kiwi.so
COPY --from=kiwi-builder /usr/local/lib/libkiwi.so.${KIWI_VERSION} /usr/local/lib/libkiwi.so.${KIWI_VERSION}
COPY --from=kiwi-builder /opt/kiwi-model /opt/kiwi-model
RUN ln -s libkiwi.so.${KIWI_VERSION} /usr/local/lib/libkiwi.so.0 && \
    ln -s libkiwi.so.${KIWI_VERSION} /usr/local/lib/libkiwi.so && \
    ldconfig

# timezone: PostgreSQL 세션 기본 타임존 / cron.timezone: pg_cron 스케줄 해석 기준 타임존
# (cron.timezone은 pg_cron 자체 GUC로 OS·PostgreSQL 타임존과 별개로 설정해야 함. 기본값은 GMT)
# --lc-collate=C --lc-ctype=C: 실제 한글 검색/정렬은 PGroonga(Groonga)가 처리하므로
# PostgreSQL 자체 collation은 로케일 종속 정렬 대신 C(byte-order)로 고정한다.
# 로케일 기반 collation은 OS 업그레이드 시 glibc 컬레이션 버전이 바뀌면 기존 B-tree
# 인덱스가 조용히 깨질 수 있는데(REINDEX 필요), C는 그런 위험이 없고 더 빠르다.
ENV POSTGRES_INITDB_ARGS="--encoding=UTF-8 --lc-collate=C --lc-ctype=C -c shared_preload_libraries=pg_cron -c timezone=Asia/Seoul -c cron.timezone=Asia/Seoul"

RUN mkdir -p /docker-entrypoint-initdb.d && \
    echo "CREATE EXTENSION IF NOT EXISTS pg_cron;" > /docker-entrypoint-initdb.d/01-pg_cron.sql && \
    printf '%s\n%s\n' \
      "CREATE EXTENSION IF NOT EXISTS pgroonga;" \
      "SELECT pgroonga_command('register tokenizers/kiwi');" \
      > /docker-entrypoint-initdb.d/02-pgroonga.sql && \
    echo "CREATE EXTENSION IF NOT EXISTS postgis;" > /docker-entrypoint-initdb.d/03-postgis.sql
