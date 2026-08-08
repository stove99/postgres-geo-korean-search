-- 실전 풀텍스트 검색 쿼리 모음
--
-- 단순 키워드 매칭(LIKE로도 되는 수준)이 아니라, 실제 서비스에서 만날 법한
-- 시나리오를 기준으로 구성했다. 각 쿼리는 그 자체로 "이 화면/이 API에 그대로
-- 쓸 수 있는" 형태를 목표로 한다.

-- ============================================================
-- 시나리오 1: 검색 결과 페이지
-- 키워드 검색 + 관련도(score) 정렬 + 스니펫 하이라이트 + 페이지네이션(LIMIT/OFFSET)
-- ============================================================
SELECT '1. 검색 결과 페이지: "여행" (1페이지, 페이지당 5건)' AS scenario;
SELECT id, title, category,
       pgroonga_score(tableoid, ctid) AS score,
       pgroonga_snippet_html(body, ARRAY['여행'], 40) AS snippet
FROM articles
WHERE body &@~ '여행'
ORDER BY score DESC, id
LIMIT 5 OFFSET 0;

-- ============================================================
-- 시나리오 2: 게시판 카테고리 탭 + 검색어 조합
-- "여행" 카테고리 탭에 들어가서 "맛있"을 검색하는 경우
-- ============================================================
SELECT '2. 카테고리 필터 + 키워드: category=travel AND "맛있"' AS scenario;
SELECT id, title, category, pgroonga_score(tableoid, ctid) AS score
FROM articles
WHERE category = 'travel' AND body &@ '맛있'
ORDER BY score DESC, id;

-- ============================================================
-- 시나리오 3: 제목/본문 통합검색 + 제목 매치 가중치
-- 제목에 검색어가 들어있으면 본문에만 있는 글보다 우선 노출한다.
-- (articles.title에도 TokenKiwi 인덱스가 있어야 함 -> 03_index.sql)
-- ============================================================
SELECT '3. 제목 가중치 통합검색: "맛집" (제목 매치가 상단)' AS scenario;
SELECT id, title,
       (CASE WHEN title &@ '맛집' THEN 10 ELSE 0 END
        + coalesce(pgroonga_score(tableoid, ctid), 0)) AS ranked_score,
       (title &@ '맛집') AS title_hit
FROM articles
WHERE title &@ '맛집' OR body &@ '맛집'
ORDER BY ranked_score DESC, id;

-- ============================================================
-- 시나리오 4: 이커머스 상품 필터 검색
-- 키워드 + 가격대 필터 + 가격순 정렬 (검색 페이지의 "필터 적용" 그 자체)
-- ============================================================
SELECT '4. 상품 필터 검색: "카메라" + 10만원~60만원' AS scenario;
SELECT id, name, brand, price
FROM products
WHERE name &@ '카메라' AND price BETWEEN 100000 AND 600000
ORDER BY price ASC;

-- ============================================================
-- 시나리오 5: 검색창 자동완성 API
-- 타이핑 도중 호출되므로 응답이 짧고 빨라야 한다 (LIMIT로 개수 제한)
-- ============================================================
SELECT '5. 자동완성 API: "삼성전" (상위 5건)' AS scenario;
SELECT id, name FROM products
WHERE name &@ '삼성전'
ORDER BY id
LIMIT 5;

-- ============================================================
-- 시나리오 6: 연관 게시물 추천
-- 상세 페이지 하단의 "이런 글도 보셨어요" — 같은 카테고리 + 핵심 키워드 공유
-- ============================================================
SELECT '6. 연관 게시물 추천: id=8(travel)과 "맛집"을 공유하는 다른 글' AS scenario;
SELECT id, title, pgroonga_score(tableoid, ctid) AS score
FROM articles
WHERE category = (SELECT category FROM articles WHERE id = 8)
  AND id <> 8
  AND body &@ '맛집'
ORDER BY score DESC, id
LIMIT 3;

-- ============================================================
-- 시나리오 7: 검색결과 없음 방지 (정밀 검색 실패 시 완화 검색으로 재시도)
-- 실제 검색 UX에서 흔한 패턴: AND로 먼저 찾고, 0건이면 OR로 넓혀서 재검색
-- ============================================================
SELECT '7-0. 정밀 AND 검색(결과 없음 확인): "캠핑카 리뷰"' AS scenario;
SELECT count(*) FROM articles WHERE body &@~ '캠핑카 리뷰';

SELECT '7-1. 완화 OR 검색 재시도: "캠핑카 OR 리뷰"' AS scenario;
SELECT id, title, category, pgroonga_score(tableoid, ctid) AS score
FROM articles WHERE body &@~ '캠핑카 OR 리뷰'
ORDER BY score DESC, id
LIMIT 5;

-- ============================================================
-- 시나리오 8: 표기 변형 대응 (동의어/이형태 확장 검색)
-- "제주"만 검색하면 "제주도"로 쓴 글을 놓친다 -> OR로 표기 변형을 함께 검색
-- ============================================================
SELECT '8-0. "제주"만 검색 (표기 변형 문서를 놓치는지 확인)' AS scenario;
SELECT id, title FROM articles WHERE body &@ '제주' ORDER BY id;

SELECT '8-1. 표기 변형 확장: "제주 OR 제주도"' AS scenario;
SELECT id, title FROM articles WHERE body &@~ '제주 OR 제주도' ORDER BY id;

-- ============================================================
-- 시나리오 9: 상세 페이지 검색어 하이라이트
-- 검색을 거쳐 들어온 상세 페이지에서 본문 중 검색어를 강조 표시
-- ============================================================
SELECT '9. 상세 페이지 하이라이트: "형태소"' AS scenario;
SELECT id, title, pgroonga_highlight_html(body, ARRAY['형태소']) AS highlighted
FROM articles WHERE body &@ '형태소';

-- ============================================================
-- 시나리오 10: 운영 대시보드 — 키워드 언급 추이 집계
-- "관리"라는 단어가 어느 카테고리에서 얼마나 언급되는지 (컨텐츠 기획/모니터링용)
-- ============================================================
SELECT '10. 운영 대시보드: 카테고리별 "관리" 언급 건수' AS scenario;
SELECT category, count(*) AS mentions
FROM articles WHERE body &@ '관리'
GROUP BY category
ORDER BY mentions DESC;

-- ============================================================
-- 시나리오 11: [주의] pgroonga 인덱스가 있는 컬럼에 순수 LIKE를 쓰면 안 되는 이유
-- articles.body에 pgroonga 인덱스가 있으면, 플래너가 LIKE도 그 인덱스로 가속한다.
-- 그런데 이때 LIKE의 "의미"까지 pgroonga의 토큰 매칭으로 바뀌어버려서,
-- 진짜 LIKE라면 걸려야 할 문서를 조용히(에러 없이) 놓친다.
-- ============================================================
SELECT '11-0. LIKE (인덱스 경유 — 기본 상태, 위험)' AS scenario;
SELECT id, title FROM articles WHERE body LIKE '%전문%' ORDER BY id;

SET enable_bitmapscan = off;
SET enable_indexscan = off;

SELECT '11-1. LIKE (순차 스캔 강제 — 진짜 LIKE 의미론)' AS scenario;
SELECT id, title FROM articles WHERE body LIKE '%전문%' ORDER BY id;

RESET enable_bitmapscan;
RESET enable_indexscan;
