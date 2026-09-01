/* PDF 의 FlateDecode 스트림을 푸는 얇은 래퍼.
 *
 * 예전에는 mz_uncompress 를 썼다. 그 안의 mz_inflateInit 이 해동기 상태
 * (11KB 남짓)를 C 의 malloc 으로 잡는데, wasi 의 malloc 은 __heap_base 부터
 * 메모리를 늘려 가며 나눠 준다 — 우리 구역 할당기가 쓰는 바로 그 메모리다.
 * 둘이 같은 자리를 서로 제 것이라 여겨, 스트림을 푸는 동안 이웃 표가
 * 덮였다. 실제로 글꼴 표 한가운데에 zlib 머리(78 9c)와 해동기 상태가
 * 찍혀 있었고, 그 글꼴로 찍은 글자가 깨져 나왔다.
 *
 * tinfl 저수준 판은 상태를 스택에 둔다. malloc 을 아예 부르지 않는다. */
#include "miniz.h"

int pw_inflate(const void *src, unsigned int src_len, void *dst, unsigned int dst_cap) {
    size_t out = tinfl_decompress_mem_to_mem(dst, dst_cap, src, src_len,
                                             TINFL_FLAG_PARSE_ZLIB_HEADER);
    if (out == TINFL_DECOMPRESS_MEM_TO_MEM_FAILED) {
        /* zlib 머리 없이 날 deflate 로 들어 있는 스트림도 있다 */
        out = tinfl_decompress_mem_to_mem(dst, dst_cap, src, src_len, 0);
        if (out == TINFL_DECOMPRESS_MEM_TO_MEM_FAILED) return 0;
    }
    return (int)out;
}
