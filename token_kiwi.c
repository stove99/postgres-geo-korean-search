/*
 * TokenKiwi: Groonga/PGroonga용 커스텀 토크나이저 플러그인.
 * Kiwi(https://github.com/bab2min/Kiwi) 형태소 분석기를 사용해
 * 한글 텍스트를 형태소 단위로 분리한다.
 *
 * 인덱스 생성 예:
 *   CREATE INDEX ON t USING pgroonga (body pgroonga_text_full_text_search_ops_v2)
 *     WITH (tokenizer='TokenKiwi');
 */
#include <groonga/tokenizer.h>
#include <groonga/string.h>
#include <kiwi/capi.h>

#include <string.h>

#ifndef KIWI_MODEL_PATH
#define KIWI_MODEL_PATH "/opt/kiwi-model/models/cong/base"
#endif

/*
 * Kiwi의 형태소 분석은 입력 길이에 비례하지 않고 늘어질 수 있다
 * (실측: 공백 없는 50KB 단일 문자열 분석에 약 2.3초, 125KB 문장 반복은 약 4.4초).
 * 이 tokenizer는 CREATE INDEX/INSERT/UPDATE/검색 시점에 PostgreSQL 백엔드
 * 안에서 동기적으로 호출되므로, 캡 없이 큰 문서(악의적이든 우연이든)가 들어오면
 * 그 시간만큼 백엔드가 멈춘다. 그래서 분석 대상 길이에 상한을 둔다.
 * 초과분은 분석에서만 제외되고(원본 컬럼 값은 그대로 저장됨) 검색 대상에서
 * 빠지므로, 이 값을 넘는 뒷부분에 있는 단어는 검색되지 않을 수 있다.
 */
#ifndef KIWI_MAX_ANALYZE_BYTES
#define KIWI_MAX_ANALYZE_BYTES (256 * 1024)
#endif

static kiwi_h global_kiwi = NULL;

typedef struct {
  kiwi_res_h result;
  int n_tokens;
  int current;
} kiwi_tokenizer_data;

static void *
kiwi_token_init(grn_ctx *ctx, grn_tokenizer_query *query)
{
  kiwi_tokenizer_data *tokenizer;
  grn_obj *normalized;
  const char *normalized_string = NULL;
  unsigned int normalized_length = 0;

  tokenizer = GRN_PLUGIN_MALLOC(ctx, sizeof(kiwi_tokenizer_data));
  if (!tokenizer) {
    GRN_PLUGIN_ERROR(ctx, GRN_NO_MEMORY_AVAILABLE,
                      "[tokenizer][kiwi] failed to allocate tokenizer data");
    return NULL;
  }
  tokenizer->result = NULL;
  tokenizer->n_tokens = 0;
  tokenizer->current = 0;

  if (!global_kiwi) {
    /* GRN_PLUGIN_INIT에서 모델 로딩이 실패한 상태.
     * 검색 자체가 조용히 0건이 되는 것을 막기 위해 에러를 남기고,
     * next_func는 빈 토큰(LAST)만 내보내 크래시 없이 안전하게 끝난다. */
    GRN_PLUGIN_ERROR(ctx, GRN_UNKNOWN_ERROR,
                      "[tokenizer][kiwi] kiwi model is not loaded, "
                      "returning no tokens");
    return tokenizer;
  }

  normalized = grn_tokenizer_query_get_normalized_string(ctx, query);
  if (!normalized) {
    return tokenizer;
  }
  grn_string_get_normalized(ctx, normalized,
                             &normalized_string, &normalized_length, NULL);

  if (normalized_string && normalized_length > 0) {
    char *nul_terminated;
    unsigned int analyze_length = normalized_length;

    if (analyze_length > KIWI_MAX_ANALYZE_BYTES) {
      analyze_length = KIWI_MAX_ANALYZE_BYTES;
      /* UTF-8 문자 중간을 자르지 않도록 이어지는 바이트(continuation byte,
       * 10xxxxxx)만큼 경계를 뒤로 물린다. */
      while (analyze_length > 0 &&
             (normalized_string[analyze_length] & 0xC0) == 0x80) {
        analyze_length--;
      }
      GRN_PLUGIN_LOG(ctx, GRN_LOG_WARNING,
                     "[tokenizer][kiwi] input is %u bytes, "
                     "analyzing only the first %u bytes",
                     normalized_length, analyze_length);
    }

    nul_terminated = GRN_PLUGIN_MALLOC(ctx, analyze_length + 1);
    if (!nul_terminated) {
      GRN_PLUGIN_ERROR(ctx, GRN_NO_MEMORY_AVAILABLE,
                        "[tokenizer][kiwi] failed to allocate input buffer");
      return tokenizer;
    }
    memcpy(nul_terminated, normalized_string, analyze_length);
    nul_terminated[analyze_length] = '\0';

    {
      kiwi_analyze_option_t option = {0};
      option.match_options = KIWI_MATCH_ALL_WITH_NORMALIZING;
      tokenizer->result = kiwi_analyze(global_kiwi, nul_terminated, 1, option, NULL);
    }
    GRN_PLUGIN_FREE(ctx, nul_terminated);

    if (!tokenizer->result) {
      GRN_PLUGIN_ERROR(ctx, GRN_UNKNOWN_ERROR,
                        "[tokenizer][kiwi] kiwi_analyze() failed");
    } else {
      tokenizer->n_tokens = kiwi_res_word_num(tokenizer->result, 0);
    }
  }

  return tokenizer;
}

static void
kiwi_token_next(grn_ctx *ctx,
                grn_tokenizer_query *query,
                grn_token *token,
                void *user_data)
{
  kiwi_tokenizer_data *tokenizer = user_data;
  const char *form;
  unsigned int form_length;

  if (!tokenizer || !tokenizer->result || tokenizer->current >= tokenizer->n_tokens) {
    grn_token_set_data(ctx, token, "", 0);
    /* REACH_END를 같이 세팅하지 않으면 Groonga가 "아직 입력 중인 단어"로 보고
     * 마지막 토큰을 접두어 검색으로 확장해버려, 예를 들어 "전문" 검색이
     * "전문가과정" 문서까지 잘못 매칭하는 문제가 생긴다. */
    grn_token_set_status(ctx, token, GRN_TOKEN_LAST | GRN_TOKEN_REACH_END);
    return;
  }

  form = kiwi_res_form(tokenizer->result, 0, tokenizer->current);
  form_length = form ? (unsigned int)strlen(form) : 0;

  grn_token_set_data(ctx, token, form ? form : "", form_length);
  {
    grn_token_status status = GRN_TOKEN_CONTINUE;
    if (tokenizer->current == tokenizer->n_tokens - 1) {
      status = GRN_TOKEN_LAST | GRN_TOKEN_REACH_END;
    }
    grn_token_set_status(ctx, token, status);
  }

  tokenizer->current++;
}

static void
kiwi_token_fin(grn_ctx *ctx, void *user_data)
{
  kiwi_tokenizer_data *tokenizer = user_data;

  if (!tokenizer) {
    return;
  }
  if (tokenizer->result) {
    kiwi_res_close(tokenizer->result);
  }
  GRN_PLUGIN_FREE(ctx, tokenizer);
}

grn_rc
GRN_PLUGIN_INIT(grn_ctx *ctx)
{
  global_kiwi = kiwi_init(KIWI_MODEL_PATH, 1, KIWI_BUILD_DEFAULT, KIWI_DIALECT_STANDARD);
  if (!global_kiwi) {
    GRN_PLUGIN_ERROR(ctx, GRN_UNKNOWN_ERROR,
                      "[tokenizer][kiwi] failed to load kiwi model from "
                      KIWI_MODEL_PATH);
    return ctx->rc;
  }
  return GRN_SUCCESS;
}

grn_rc
GRN_PLUGIN_REGISTER(grn_ctx *ctx)
{
  grn_obj *tokenizer;

  tokenizer = grn_tokenizer_create(ctx, "TokenKiwi", -1);
  if (!tokenizer) {
    return ctx->rc;
  }
  grn_tokenizer_set_init_func(ctx, tokenizer, kiwi_token_init);
  grn_tokenizer_set_next_func(ctx, tokenizer, kiwi_token_next);
  grn_tokenizer_set_fin_func(ctx, tokenizer, kiwi_token_fin);
  return GRN_SUCCESS;
}

grn_rc
GRN_PLUGIN_FIN(grn_ctx *ctx)
{
  if (global_kiwi) {
    kiwi_close(global_kiwi);
    global_kiwi = NULL;
  }
  return GRN_SUCCESS;
}
