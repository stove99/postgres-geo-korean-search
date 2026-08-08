-- 샘플 스키마: 한글 Full Text 검색(PGroonga + TokenKiwi/TokenBigram) 데모용
--
-- articles: 문장형 자연어 텍스트(블로그/뉴스 본문) -> TokenKiwi에 적합한 예시
-- products: 짧은 상품명(자동완성 대상) -> TokenBigram에 적합한 예시

CREATE TABLE IF NOT EXISTS articles (
    id          serial PRIMARY KEY,
    title       text NOT NULL,
    body        text NOT NULL,
    category    text NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS products (
    id          serial PRIMARY KEY,
    name        text NOT NULL,
    brand       text NOT NULL,
    price       integer NOT NULL
);
