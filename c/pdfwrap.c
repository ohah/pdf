/* PDF 의 FlateDecode 스트림을 푸는 얇은 래퍼. miniz 의 zlib 호환 API 를 쓴다. */
#include "miniz.h"

int pw_inflate(const void *src, unsigned int src_len, void *dst, unsigned int dst_cap) {
    mz_ulong out_len = dst_cap;
    int r = mz_uncompress((unsigned char *)dst, &out_len, (const unsigned char *)src, src_len);
    if (r != MZ_OK) return 0;
    return (int)out_len;
}
