-- 샘플 인덱스 생성
-- articles.body: 문장형 자연어 -> TokenKiwi (형태소 단위, 정밀 검색/랭킹)
CREATE INDEX IF NOT EXISTS idx_articles_body_kiwi ON articles
    USING pgroonga (body pgroonga_text_full_text_search_ops_v2)
    WITH (tokenizer='TokenKiwi');

-- articles.title: 제목도 검색 대상에 포함 (제목/본문 통합검색, 제목 가중치 랭킹용)
CREATE INDEX IF NOT EXISTS idx_articles_title_kiwi ON articles
    USING pgroonga (title pgroonga_text_full_text_search_ops_v2)
    WITH (tokenizer='TokenKiwi');

-- products.name: 짧은 상품명, 자동완성 대상 -> TokenBigram (부분/접두어 매칭)
CREATE INDEX IF NOT EXISTS idx_products_name_bigram ON products
    USING pgroonga (name pgroonga_text_full_text_search_ops_v2)
    WITH (tokenizer='TokenBigram');
