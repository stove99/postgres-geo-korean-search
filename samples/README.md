# 실전 풀텍스트 검색 쿼리 결과 문서

`samples/` 폴더의 스키마·데이터·인덱스를 이용해 실제로
`ghcr.io/stove99/postgres-geo-korean-search:18-3.6` 컨테이너에서 검색을 실행한 결과입니다.

단순 키워드 매칭(`LIKE`로도 되는 수준)이 아니라, **실제 서비스에서 만날 법한 시나리오** —
검색 결과 페이지, 카테고리 필터, 상품 필터, 자동완성, 연관 게시물 추천, 검색결과 없음 방지,
표기 변형 대응, 운영 대시보드 — 기준으로 쿼리를 구성했습니다.

## 구성 파일

| 파일 | 내용 |
|---|---|
| [01_schema.sql](01_schema.sql) | `articles`(블로그/뉴스 본문), `products`(짧은 상품명) 테이블 정의 |
| [02_data.sql](02_data.sql) | 샘플 데이터 전체 — articles 195건 (12개 카테고리) + products 65건 (16개 브랜드) |
| [03_index.sql](03_index.sql) | `articles.body`/`articles.title` → TokenKiwi, `products.name` → TokenBigram 인덱스 생성 |
| [04_search_queries.sql](04_search_queries.sql) | 아래 결과를 만들어낸 실제 쿼리 (11개 시나리오) |

재현하려면:

```bash
docker run -d --name pg-samples-demo -e POSTGRES_PASSWORD=<비밀번호> -p 15432:5432 \
  ghcr.io/stove99/postgres-geo-korean-search:18-3.6

for f in 01_schema.sql 02_data.sql 03_index.sql 04_search_queries.sql; do
  docker cp "$f" pg-samples-demo:/tmp/"$f"
  docker exec -u postgres pg-samples-demo psql -v ON_ERROR_STOP=1 -f /tmp/"$f"
done
```

---

## 1. 검색 결과 페이지 — 관련도 정렬 + 스니펫 + 페이지네이션

검색창에 "여행"을 입력했을 때 실제 검색 결과 페이지에 그대로 쓸 수 있는 형태. 관련도(`pgroonga_score`) 순으로 정렬하고, 각 결과에 검색어가 강조된 스니펫을 함께 내려준다.

```sql
SELECT id, title, category,
       pgroonga_score(tableoid, ctid) AS score,
       pgroonga_snippet_html(body, ARRAY['여행'], 40) AS snippet
FROM articles
WHERE body &@~ '여행'
ORDER BY score DESC, id
LIMIT 5 OFFSET 0;
```

| id | title | category | score | snippet |
|---|---|---|---|---|
| 46 | 속초 당일치기 여행 | travel | 2 | "속초 **여행** 코스를 정리했습니" / "다. 강릉 **여행** 코스를 정리했" |
| 60 | 통영 여행기 | travel | 2 | "통영 **여행** 코스를 정리했습니" / "다. 보성 **여행** 코스를 정리했" |
| 49 | 군산 여행 코스 정리 | travel | 1 | "군산 **여행** 코스를 정리했습니" |
| 50 | 보성 여행 코스 정리 | travel | 1 | "다. 거제도 **여행** 코스를 정리" |
| 52 | 부산 여행 후기 | travel | 1 | "부산 **여행** 코스를 정리했습니" |

본문에 "여행"이 두 번 언급된 글이 자동으로 상위에 오르고, 각 결과에 바로 보여줄 수 있는 스니펫까지 한 번의 쿼리로 나온다.

## 2. 카테고리 필터 + 키워드 조합

게시판에서 "여행" 카테고리 탭을 선택한 채로 "맛있"을 검색하는 경우. 일반 `WHERE` 조건과 풀텍스트 검색을 자연스럽게 섞어 쓸 수 있다는 게 핵심이다.

```sql
SELECT id, title, category, pgroonga_score(tableoid, ctid) AS score
FROM articles
WHERE category = 'travel' AND body &@ '맛있'
ORDER BY score DESC, id;
```

| id | title | category | score |
|---|---|---|---|
| 8 | 제주도 여행 맛집 정리 | travel | 1 |
| 47 | 통영 여행 계획 | travel | 1 |
| 48 | 강릉 여행 후기 | travel | 1 |
| 52 | 부산 여행 후기 | travel | 1 |
| 54 | 전주 여행기 | travel | 1 |
| 56 | 강릉 여행기 | travel | 1 |

## 3. 제목/본문 통합검색 + 제목 매치 가중치

"맛집"을 검색했을 때 제목에 "맛집"이 들어간 글을 본문에만 있는 글보다 우선 노출시키는, 실제 검색엔진이 흔히 쓰는 랭킹 부스팅 패턴이다. `articles.title`에도 TokenKiwi 인덱스가 있어야 한다.

```sql
SELECT id, title,
       (CASE WHEN title &@ '맛집' THEN 10 ELSE 0 END
        + coalesce(pgroonga_score(tableoid, ctid), 0)) AS ranked_score,
       (title &@ '맛집') AS title_hit
FROM articles
WHERE title &@ '맛집' OR body &@ '맛집'
ORDER BY ranked_score DESC, id;
```

| id | title | ranked_score | title_hit |
|---|---|---|---|
| 8 | 제주도 여행 맛집 정리 | 13 | t |
| 13 | 제주 흑돼지 맛집 탐방 | 12 | t |
| 22 | 김밥 맛집 후기 | 12 | t |
| 23 | 비빔밥 맛집 탐방기 | 12 | t |
| 26 | 피자 맛집 후기 | 12 | t |
| 27 | 라멘 맛집 후기 | 12 | t |
| 17 | 비빔밥 맛집 후기 | 11 | t |
| 18 | 김밥 맛집 후기 | 11 | t |
| 19 | 칼국수 맛집 후기 | 11 | t |
| 21 | 파스타 맛집 탐방기 | 11 | t |
| 24 | 잡채 맛집 탐방기 | 11 | t |
| 16 | 된장찌개 먹은 이야기 | 1 | f |
| 25 | 만두 레시피 정리 | 1 | f |
| 28 | 비빔밥 먹은 이야기 | 1 | f |

제목에 "맛집"이 있는 11건이 전부 위로 올라가고, 본문에만 언급된 3건(id 16, 25, 28)이 맨 아래로 밀린다.

## 4. 이커머스 상품 필터 검색 — 키워드 + 가격대

검색창에 "카메라"를 입력하고 가격 슬라이더로 10만원~60만원을 지정한 경우. 전체 "카메라" 상품은 4건이지만 가격 필터로 2건만 남는다.

```sql
SELECT id, name, brand, price
FROM products
WHERE name &@ '카메라' AND price BETWEEN 100000 AND 600000
ORDER BY price ASC;
```

| id | name | brand | price |
|---|---|---|---|
| 62 | 캐논 DSLR 카메라 5세대 | 캐논 | 359,000 |
| 61 | 캐논 미러리스 카메라 Pro | 캐논 | 499,000 |

(참고: 필터링 전 전체 "카메라" 상품은 니콘 59,000원, 소니 1,890,000원까지 포함해 4건이며, 가격 필터가 정확히 걸러낸다.)

## 5. 검색창 자동완성 API

사용자가 "삼성전"까지 입력한 시점에 호출되는 자동완성 API. 타이핑 도중 호출되므로 응답이 짧아야 한다 (`LIMIT`으로 개수 제한).

```sql
SELECT id, name FROM products
WHERE name &@ '삼성전'
ORDER BY id
LIMIT 5;
```

| id | name |
|---|---|
| 1 | 삼성전자 갤럭시 S24 |
| 2 | 삼성전자 갤럭시 Z플립5 |
| 3 | 삼성전자 갤럭시 탭 S9 |
| 11 | 삼성전자 제트봇 로봇청소기 Air |
| 12 | 삼성전자 더프레임 TV Pro |

"삼성전자"를 다 입력하기 전에도 결과가 나온다 — TokenBigram이 부분 문자열 단위로 색인하기 때문.

## 6. 연관 게시물 추천

상세 페이지 하단의 "이런 글도 보셨어요" 영역. 같은 카테고리 안에서 핵심 키워드를 공유하는 다른 글을 찾는다.

```sql
SELECT id, title, pgroonga_score(tableoid, ctid) AS score
FROM articles
WHERE category = (SELECT category FROM articles WHERE id = 8)
  AND id <> 8
  AND body &@ '맛집'
ORDER BY score DESC, id
LIMIT 3;
```

| id | title | score |
|---|---|---|
| 13 | 제주 흑돼지 맛집 탐방 | 1 |

id=8("제주도 여행 맛집 정리")과 같은 travel 카테고리에서 "맛집"을 공유하는 글은 1건뿐이라, 추천 영역도 정직하게 1건만 채워진다 — 실제 서비스에서 흔히 마주치는 "추천할 게 별로 없는" 상황까지 그대로 재현된다.

## 7. 검색결과 없음 방지 — 정밀 검색 실패 시 완화 검색 재시도

흔한 UX 패턴: AND로 정밀 검색해서 0건이면, 그대로 "검색 결과 없음"을 보여주지 않고 OR로 완화해서 재검색한다.

```sql
-- 1차: 정밀 AND 검색
SELECT count(*) FROM articles WHERE body &@~ '캠핑카 리뷰';
```

| count |
|---|
| 0 |

```sql
-- 0건이므로 OR로 완화해서 재시도
SELECT id, title, category, pgroonga_score(tableoid, ctid) AS score
FROM articles WHERE body &@~ '캠핑카 OR 리뷰'
ORDER BY score DESC, id
LIMIT 5;
```

| id | title | category | score |
|---|---|---|---|
| 66 | 전동 킥보드 구매 후기 | review | 2 |
| 72 | 카메라 렌즈 사용기 | review | 2 |
| 15 | 전문 카메라 장비 리뷰 | review | 1 |
| 61 | 가습기 사용기 | review | 1 |
| 63 | 커피머신 사용기 | review | 1 |

## 8. 표기 변형 대응 (동의어/이형태 확장 검색)

사용자가 "제주"라고만 검색하면 "제주도"라고 쓴 글을 놓친다. TokenKiwi가 "제주도"를 하나의 고유명사 토큰으로 인식해서 "제주"와 별개 토큰으로 색인하기 때문이다.

```sql
-- "제주"만 검색 — "제주도" 문서를 놓친다
SELECT id, title FROM articles WHERE body &@ '제주' ORDER BY id;
```

| id | title |
|---|---|
| 13 | 제주 흑돼지 맛집 탐방 |

```sql
-- 표기 변형까지 OR로 확장
SELECT id, title FROM articles WHERE body &@~ '제주 OR 제주도' ORDER BY id;
```

| id | title |
|---|---|
| 8 | 제주도 여행 맛집 정리 |
| 13 | 제주 흑돼지 맛집 탐방 |
| 57 | 제주도 여행 계획 |

"제주"만 검색하면 1건, "제주 OR 제주도"로 확장하면 3건. 실제 서비스라면 이런 표기 변형 목록을 동의어 사전으로 관리하면서 쿼리 생성 시점에 자동으로 OR를 붙여주는 방식을 쓴다.

## 9. 상세 페이지 검색어 하이라이트

검색을 거쳐 들어온 상세 페이지에서 본문 중 검색어를 강조 표시.

```sql
SELECT id, title, pgroonga_highlight_html(body, ARRAY['형태소']) AS highlighted
FROM articles WHERE body &@ '형태소';
```

```html
<!-- id 1 -->
이 글에서는 전문 검색 엔진을 처음부터 구축하는 방법을 다룬다.
색인 구조와 <span class="keyword">형태소</span> 분석기의 역할을 함께 설명한다.

<!-- id 12 -->
한글 <span class="keyword">형태소</span> 분석기를 여러 개 비교해봤다.
사전 기반 분석기와 통계 기반 분석기는 각각 장단점이 뚜렷했다.
```

## 10. 운영 대시보드 — 키워드 언급 추이 집계

콘텐츠 기획/모니터링용 대시보드에서 "관리"라는 단어가 어느 카테고리에서 얼마나 언급되는지 집계.

```sql
SELECT category, count(*) AS mentions
FROM articles WHERE body &@ '관리'
GROUP BY category
ORDER BY mentions DESC;
```

| category | mentions |
|---|---|
| health | 8 |
| finance | 1 |

## 11. [주의] pgroonga 인덱스가 있는 컬럼에 순수 LIKE를 쓰면 안 되는 이유

테스트 중 발견한, 문서화되지 않은 함정. `articles.body`에 pgroonga 인덱스가 있는 상태에서 평범한 `LIKE '%전문%'`를 실행하면:

```sql
SELECT id, title FROM articles WHERE body LIKE '%전문%' ORDER BY id;
```

| id | title |
|---|---|
| 1 | 전문 검색 엔진 만들기 |
| 15 | 전문 카메라 장비 리뷰 |

플래너가 이 LIKE 쿼리를 pgroonga 인덱스로 가속하면서(`Bitmap Index Scan`), 결과가 형태소 매칭(`&@ '전문'`)과 똑같이 2건만 나온다. `enable_bitmapscan`/`enable_indexscan`을 꺼서 강제로 순차 스캔을 시키면:

```sql
SET enable_bitmapscan = off;
SET enable_indexscan = off;
SELECT id, title FROM articles WHERE body LIKE '%전문%' ORDER BY id;
```

| id | title |
|---|---|
| 1 | 전문 검색 엔진 만들기 |
| 2 | 전문가과정 후기 |
| 15 | 전문 카메라 장비 리뷰 |
| 122 | 연금저축 전략 노트 |
| 123 | 채권 투자 공부 정리 |
| 133 | 주식 투자 상담 후기 |
| 134 | 절세 공부 정리 |

그제서야 "전문가과정"을 포함한 진짜 LIKE 결과 7건이 나온다. **즉 pgroonga 인덱스가 걸린 컬럼에 순수 LIKE를 쓰면, 진짜로 걸려야 할 문서를 에러 없이 조용히 놓칠 수 있다.** 그 컬럼에서 순수 부분 문자열 매칭이 필요하다면 `LIKE` 대신 pg_trgm 같은 별도 인덱스를 쓰거나, 애초에 원하는 매칭 방식(형태소 vs 부분 문자열)에 맞는 pgroonga 연산자(`&@`, `&@~`)를 써야 한다.

---

## 요약

| 시나리오 | 핵심 |
|---|---|
| 1 | 관련도 정렬 + 스니펫 하이라이트를 한 쿼리로 |
| 2 | 일반 WHERE 조건과 풀텍스트 검색의 자연스러운 결합 |
| 3 | 제목 매치 가중치로 랭킹 부스팅 |
| 4 | 풀텍스트 검색 + 범위 필터(가격) 조합 |
| 5 | 자동완성 API — 짧고 빠른 응답 |
| 6 | 연관 콘텐츠 추천 |
| 7 | 검색결과 없음 방지 (정밀 → 완화 재시도) |
| 8 | 표기 변형/동의어 확장 검색의 필요성 |
| 9 | 검색어 하이라이트 |
| 10 | 운영 대시보드용 집계 |
| 11 | **pgroonga 인덱스가 있으면 LIKE의 의미 자체가 바뀐다 — 가장 중요한 주의사항** |

이 문서의 모든 결과는 실제 컨테이너(`ghcr.io/stove99/postgres-geo-korean-search:18-3.6`)에서
`samples/`의 스크립트를 그대로 실행해 얻은 것이며, 재현 명령은 상단을 참고하세요.
