# postgres-geo-korean-search

PostgreSQL 18(Debian trixie) 기반에 **PostGIS**, **pg_cron**, **PGroonga**를 얹고, PGroonga용 커스텀 토크나이저 **TokenKiwi**(한글 형태소 분석기 [Kiwi](https://github.com/bab2min/Kiwi) 기반)를 추가한 이미지입니다.

## 포함된 구성 요소

| 구성 요소 | 버전 | 설치 방식 |
|---|---|---|
| PostgreSQL | 18.4 | 공식 `postgres:18-trixie` 베이스 이미지 |
| PostGIS | 3.6.4 | Debian trixie 공식 apt 패키지 (`postgresql-18-postgis-3`) |
| pg_cron | 1.6 | Debian trixie 공식 apt 패키지 (`postgresql-18-cron`) |
| PGroonga | 4.0.8 (Groonga 16.0.9) | groonga.org apt 저장소 (`postgresql-18-pgdg-pgroonga`) |
| TokenKiwi | Kiwi 0.23.2 | 이 저장소의 `token_kiwi.c`를 소스로 직접 빌드하는 커스텀 Groonga 토크나이저 플러그인 |

모든 확장은 `postgres` DB 초기화 시(`/docker-entrypoint-initdb.d/*.sql`) 자동으로 `CREATE EXTENSION`되고, TokenKiwi도 자동으로 `pgroonga_command('register tokenizers/kiwi')`로 등록됩니다. 수동 설정 없이 바로 사용할 수 있습니다.

이미지 크기는 약 **1.34GB**입니다.

## 빠른 시작

### 1. 로컬에서 빌드해서 실행

```bash
docker build -t postgres-geo-korean-search .
docker run -d --name pg \
  -e POSTGRES_PASSWORD=<비밀번호> \
  -p 5432:5432 \
  postgres-geo-korean-search
```

### 2. ghcr.io에서 이미지 받아서 실행

[GitHub Actions](.github/workflows/docker-publish.yml)가 `main` 브랜치 푸시마다 `ghcr.io/stove99/postgres-geo-korean-search`로 빌드·푸시합니다.

```bash
docker pull ghcr.io/stove99/postgres-geo-korean-search:18-3.6

docker run -d --name pg \
  -e POSTGRES_PASSWORD=<비밀번호> \
  -p 5432:5432 \
  -v pgdata:/var/lib/postgresql/18/docker \
  ghcr.io/stove99/postgres-geo-korean-search:18-3.6
```

`latest` 대신 `18-3.6` 태그를 쓰면 어떤 PostgreSQL/PostGIS 조합인지 태그만 보고 알 수 있고, 나중에 이미지가 갱신돼도 의도치 않게 버전이 바뀌지 않습니다.

### 3. docker-compose

```yaml
services:
  postgres:
    image: ghcr.io/stove99/postgres-geo-korean-search:18-3.6
    restart: unless-stopped
    environment:
      POSTGRES_PASSWORD: <비밀번호>
      # POSTGRES_DB, POSTGRES_USER 등 공식 postgres 이미지의 환경변수도 그대로 사용 가능
    ports:
      - "5432:5432"
    volumes:
      # PGDATA 기본 경로가 /var/lib/postgresql/18/docker 임에 주의
      # (흔히 쓰는 /var/lib/postgresql/data 가 아님)
      - pgdata:/var/lib/postgresql/18/docker
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER:-postgres}"]
      interval: 10s
      timeout: 5s
      retries: 5

volumes:
  pgdata:
```

```bash
docker compose up -d
```

```sql
-- 확장 확인 (세 방식 공통)
\dx
-- 결과: pg_cron, pgroonga, postgis, plpgsql
```

## 타임존 / Collation

- 이미지 OS/PostgreSQL 타임존, pg_cron 스케줄 해석 타임존(`cron.timezone`) 모두 **`Asia/Seoul`(KST)**로 고정되어 있습니다. `cron.timezone`은 pg_cron 자체 GUC라 기본값(GMT)을 별도로 맞췄습니다.
- DB의 `lc_collate`/`lc_ctype`은 **`ko_KR.utf8`**로 초기화됩니다. Full Text 검색은 필요 시에만 PGroonga로 조건부 사용하므로, PGroonga 없이도 `ORDER BY`/`LIKE`/`ILIKE` 등 기본 기능이 로케일 인식 동작을 하도록 했습니다.
  - 주의: base 이미지(`postgres:18-trixie`) 업데이트 시 glibc collation 버전이 바뀌면 기존 B-tree 인덱스가 조용히 깨질 수 있습니다. `pg_collation.collversion`을 확인하고, 필요 시 `ALTER DATABASE ... REFRESH COLLATION VERSION` + `REINDEX`를 검토하세요.

## 한글 Full Text 검색

이 이미지에서 한글 검색이 가장 공을 들인 부분입니다. PGroonga는 세 가지 토크나이저 선택지를 제공하며, 그 특성이 서로 다릅니다.

### 왜 PostgreSQL 기본 Full Text 검색(`tsvector`)이 아니라 PGroonga인가

PostgreSQL 내장 Full Text 검색은 한국어 형태소 분석 사전이 없어 한글 검색 품질이 떨어집니다. PGroonga는 [Groonga](https://groonga.org/) 검색 엔진을 PostgreSQL 인덱스(`USING pgroonga`)로 노출해, CJK(중국어·일본어·한국어)를 포함한 전 언어 Full Text 검색을 지원합니다.

### 토크나이저 선택지 비교

| | **TokenBigram** (PGroonga 기본값) | **TokenKiwi** (이 이미지의 커스텀 플러그인) |
|---|---|---|
| 방식 | 2글자씩 슬라이딩 윈도우(n-gram)로 무조건 분할 | Kiwi 통계 기반 형태소 분석기로 실제 단어 단위 분할 |
| 사전 필요 | 불필요 | 필요 (Kiwi 기본 모델, 이미지에 내장) |
| 정밀도 | 낮음 — 우연히 겹치는 글자쌍도 매칭됨 (예: "전문" 검색 시 "전문가과정"도 걸림) | 높음 — 형태소 경계를 인식해서 정밀 매칭 |
| 조사/어미 처리 | 상관없이 매칭 (부분 문자열이라 결과적으로 됨) | 형태소 단위로 분리되어 정확히 매칭 (`검색을` → `검색`+`을`) |
| 활용형 검색 | 별도 처리 없이도 부분 매칭으로 됨 | 어간 단위로 색인되어 `먹었습니다`/`먹고 있습니다`/`먹을 것입니다` 모두 `먹`으로 검색됨 |
| 신조어/오탈자 | 강함 — 사전이 없으니 새 단어도 그냥 부분 매칭됨 | Kiwi 자체의 미등록어 추론 덕분에 상당수 신조어(예: "챗지피티", "알잘딱깔센")도 하나의 형태소로 인식하지만, 완전히 새로운 조합은 기존 형태소로 쪼개질 수 있음 |
| 인덱스 크기 | 큼 (모든 2글자 조합을 색인) | 작음 (의미 단위만 색인) |
| 랭킹 품질 | 보통 | 좋음 (실제 단어 기준 TF 계산) |

두 토크나이저 모두 이 이미지에 이미 들어있습니다(TokenBigram은 Groonga 내장, TokenKiwi는 별도 컴파일). **인덱스를 만들 때 `tokenizer` 옵션으로 선택**하면 됩니다.

### 어떤 경우에 어떤 토크나이저를 써야 하는가

| 질문 | 예 → | 아니오 → |
|---|---|---|
| 완성된 문장/자연어 텍스트인가? | **TokenKiwi** | **TokenBigram** |
| 오탐 없는 정밀도가 재현율보다 중요한가? | **TokenKiwi** | **TokenBigram** |
| 사용자가 타이핑 도중(자동완성)에도 결과가 나와야 하는가? | **TokenBigram** | **TokenKiwi** |
| 고유명사·코드·URL처럼 사전에 없는 임의 문자열인가? | **TokenBigram** | **TokenKiwi** |

**한 테이블 안에서도 컬럼마다 다른 토크나이저를 섞어 써도 됩니다** — 예를 들어 `products.description`(문장형 설명)은 TokenKiwi, `products.name`(브랜드명, 자동완성 대상)은 TokenBigram으로 나눠서 인덱싱하는 식입니다.

#### TokenKiwi가 적합한 경우 — 문장형 자연어, 정밀도/랭킹이 중요할 때

조사·어미가 붙은 채로 검색어가 들어오거나, 활용형이 다양한 동사/형용사가 자주 나오는 텍스트일수록 형태소 분석의 이득이 큽니다.

```sql
-- 블로그/뉴스 게시글 본문: 문장형 텍스트라 정밀 검색·랭킹 품질이 중요
CREATE INDEX idx_posts_content ON posts
  USING pgroonga (content pgroonga_text_full_text_search_ops_v2)
  WITH (tokenizer='TokenKiwi');

-- 상품 리뷰: "맛있어요"/"맛있었습니다"/"진짜 맛있네요"처럼 활용형이 달라도
-- 어간("맛있") 기준으로 묶여서 검색됨
CREATE INDEX idx_reviews_body ON reviews
  USING pgroonga (body pgroonga_text_full_text_search_ops_v2)
  WITH (tokenizer='TokenKiwi');

-- 고객센터 Q&A: 사용자가 완성된 문장으로 질문을 입력하므로
-- 형태소 기반 매칭이 정확도를 높여줌 (엉뚱한 부분 문자열 매칭 방지)
CREATE INDEX idx_faq_question ON faq
  USING pgroonga (question pgroonga_text_full_text_search_ops_v2)
  WITH (tokenizer='TokenKiwi');
```

#### TokenBigram이 적합한 경우 — 부분 매칭·자동완성·비자연어 텍스트

TokenKiwi는 "완성된 단어"를 전제로 형태소를 분석하기 때문에, 아직 다 입력되지 않은 문자열이나 애초에 사전에 없는 임의 문자열에는 오히려 불리합니다.

```sql
-- 자동완성(타이핑 중 검색): "삼성전자"를 다 치기 전 "삼성전"만 입력해도
-- 매칭돼야 함. TokenKiwi는 완성된 단어 단위로 분석하므로 이런 잘린 입력엔 약함
CREATE INDEX idx_products_name_autocomplete ON products
  USING pgroonga (name pgroonga_text_full_text_search_ops_v2)
  WITH (tokenizer='TokenBigram');

-- 해시태그/키워드: 자연어 문장이 아니라 임의로 조합된 짧은 문자열
CREATE INDEX idx_posts_tags ON posts
  USING pgroonga (tags pgroonga_text_full_text_search_ops_v2)
  WITH (tokenizer='TokenBigram');

-- 애플리케이션 로그/에러 메시지, URL, 파일 경로: 형태소 분석 대상이 아닌 텍스트라
-- Kiwi에 넣으면 예측 불가능하게 쪼개질 수 있음
CREATE INDEX idx_logs_message ON app_logs
  USING pgroonga (message pgroonga_text_full_text_search_ops_v2)
  WITH (tokenizer='TokenBigram');
```

### 인덱스 생성

```sql
-- 정밀 검색이 필요한 경우 (권장)
CREATE INDEX idx_articles_body ON articles
  USING pgroonga (body pgroonga_text_full_text_search_ops_v2)
  WITH (tokenizer='TokenKiwi');

-- 사전 없이 강건한 부분 문자열 매칭이 필요한 경우
CREATE INDEX idx_articles_body_bigram ON articles
  USING pgroonga (body pgroonga_text_full_text_search_ops_v2)
  WITH (tokenizer='TokenBigram');

-- 옵션을 생략하면 PGroonga 기본값(TokenBigram 계열)이 사용됨
CREATE INDEX idx_articles_title ON articles USING pgroonga (title);
```

### 검색 예시

```sql
-- 쿼리 문법 검색 (OR/AND, 와일드카드 등 지원)
SELECT * FROM articles WHERE body &@~ '검색 엔진';
SELECT * FROM articles WHERE body &@~ '전문 OR 색인';
SELECT * FROM articles WHERE body &@~ '전문*';   -- 접두어 와일드카드

-- 단순 키워드 포함 검색
SELECT * FROM articles WHERE body &@ '검색';

-- 랭킹 스코어
SELECT id, title, pgroonga_score(tableoid, ctid) AS score
FROM articles WHERE body &@~ '검색' ORDER BY score DESC;

-- 검색어 하이라이트
SELECT pgroonga_highlight_html(body, ARRAY['검색']) FROM articles WHERE id = 1;

-- 요약 발췌(스니펫)
SELECT pgroonga_snippet_html(body, ARRAY['검색'], 30) FROM articles WHERE id = 1;

-- 형태소 분석 결과 직접 확인 (디버깅용)
SELECT pgroonga_command('tokenize TokenKiwi "전문검색엔진"');
```

TokenKiwi로 색인하면 `전문검색엔진` → `전문` / `검색` / `엔진` 세 개의 형태소로 분리되고, `전문가과정`은 `전문가`(복합명사) / `과정`으로 분리됩니다. 그래서 `전문`으로 검색해도 `전문가과정`과 헷갈리지 않습니다.

### TokenKiwi 구현 및 한계 (`token_kiwi.c`)

- Groonga 토크나이저 플러그인 API(`init`/`next`/`fin` 세 함수)로 구현했고, 형태소 분석 자체는 Kiwi의 C API(`kiwi_analyze`)를 그대로 호출합니다.
- **입력 길이 상한 256KB**: 형태소 분석 시간이 입력 길이에 비례하지 않고 늘어질 수 있어(공백 없는 50KB 텍스트 분석에 약 2.3초 실측), `INSERT`/`UPDATE`/`CREATE INDEX`/검색 시점에 PostgreSQL 백엔드가 오래 멈추는 걸 막기 위해 분석 대상을 256KB로 자릅니다. 원본 컬럼 값은 그대로 저장되고, 이 상한을 넘는 뒷부분의 단어만 검색 대상에서 빠집니다. 잘렸을 때는 `$PGDATA/pgroonga.log`에 경고가 남습니다.
- **모델 로딩 실패 시 안전 동작**: Kiwi 모델을 못 찾으면 `CREATE INDEX`가 명확한 SQL 에러로 실패할 뿐 서버는 죽지 않습니다.
- **알려진 한계**: 1~2글자 정도의 아주 짧은 쿼리가, 그 글자로 시작하는 더 긴 복합명사와 구분되지 않고 매칭되는 경우가 있습니다 (예: "카"로 검색하면 "카페", "카레", "카카오"가 모두 걸림). 원인은 PGroonga/Groonga의 짧은 쿼리 매칭 동작으로 추정되며 완전히 규명하지는 못했습니다. 실사용에서 큰 문제가 되는 수준은 아니라고 판단해 알려진 제약사항으로 남겨두었습니다.
- 대량의 크래시 테스트(빈 문자열, 이모지, 제로폭 문자, SQL/HTML 인젝션 유사 문자열, 10MB 이상의 극단적으로 긴 텍스트, 10개 동시 연결 등)를 거쳐 검증했습니다.

## 빌드 구조 (멀티스테이지)

```
kiwi-builder (debian:trixie-slim)          최종 이미지 (postgres:18-trixie)
  ├─ libgroonga-dev, gcc 등 빌드 도구         ├─ postgis / pgroonga / pg_cron (apt)
  ├─ Kiwi 프리빌드 바이너리+모델 다운로드        ├─ COPY: kiwi.so (컴파일된 플러그인, 49KB)
  └─ token_kiwi.c 컴파일 → kiwi.so           ├─ COPY: libkiwi.so (런타임 라이브러리, 58MB)
                                            └─ COPY: Kiwi 모델 (109MB)
```

빌드 도구(gcc, libgroonga-dev, pkg-config)는 `kiwi-builder` 스테이지에만 존재하고 최종 이미지에는 포함되지 않습니다. Kiwi는 [공식 GitHub Releases](https://github.com/bab2min/Kiwi/releases)에서 Linux x86_64용 프리빌드 바이너리와 기본 모델을 그대로 받아 쓰므로 Kiwi 자체를 소스 빌드하지는 않습니다.

## 파일 구조

```
Dockerfile       멀티스테이지 빌드 정의
token_kiwi.c     PGroonga용 커스텀 토크나이저(TokenKiwi) 플러그인 소스
```

## 참고

- [PGroonga 공식 문서](https://pgroonga.github.io/)
- [Groonga 토크나이저 작성 가이드](https://github.com/groonga/groonga-tokenizer-sample) (TokenKiwi 구현의 참고 소스)
- [Kiwi(지능형 한국어 형태소 분석기)](https://github.com/bab2min/Kiwi)
