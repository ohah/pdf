# 실문서 표본의 고른 쪽을 mupdf 로 그려 PNG 로 남긴다 (tests/corpus-render.mjs 의 셋째 눈).
#
#   <venv>/bin/python tests/corpus-mupdf.py <pdf디렉터리> <출력디렉터리> [배율=1.0]
#
# 쪽 고르기는 corpus-dump.mjs 와 같다(앞 5쪽 + 고르게 3쪽). pages.json 에 적어 둔다.
import sys, os, json, fitz
src, out = sys.argv[1], sys.argv[2]
scale = float(sys.argv[3]) if len(sys.argv) > 3 else 1.0
os.makedirs(out, exist_ok=True)
def pick(n):
    s = list(range(1, min(5, n) + 1))
    if n > 5:
        for k in (1, 2, 3):
            p = min(n, 5 + round((n - 5) * k / 3))
            if p not in s: s.append(p)
    return s[:8]
pages = {}
for f in sorted(x for x in os.listdir(src) if x.endswith('.pdf')):
    name = f[:-4]
    try:
        d = fitz.open(os.path.join(src, f))
        ps = pick(d.page_count)
        pages[name] = ps
        for p in ps:
            png = os.path.join(out, f'{name}-{p}.png')
            if os.path.exists(png): continue
            pg = d[p - 1]
            pm = pg.get_pixmap(matrix=fitz.Matrix(scale, scale), alpha=False)
            pm.save(png)
        d.close()
    except Exception as e:
        pages[name] = {'err': str(e)}
        print(name, 'ERR', e)
json.dump(pages, open(os.path.join(out, 'pages.json'), 'w'))
print('문서', len(pages), '· 그림', sum(len(v) for v in pages.values() if isinstance(v, list)))
