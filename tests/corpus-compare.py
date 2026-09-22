# 실문서 표본에서 우리 글자 뽑기를 pymupdf·pdf.js 와 맞댄다.
#
#   <venv>/bin/python tests/corpus-compare.py <pdf디렉터리> <corpus-dump 출력디렉터리> [-v]
#
# 문서·쪽마다:
#   글자 재현율/정밀도  빈칸 뺀 글자 다중집합으로 — 빠진 글자·군더더기 글자를 잡는다
#   차례            빈칸 뺀 글을 그대로 맞댄 유사도(difflib) — 읽는 차례가 다르면 떨어진다
#   자리            pymupdf 의 글자 상자와 우리 조각(폭을 글자 수로 나눔)을 글자별로 짝지어,
#                   같은 글자가 3pt(y)·6pt(x) 안에 있는 비율과 x 차이의 중앙값
#   기준끼리        pymupdf 와 pdf.js 의 글자 재현율 — 둘도 서로 다르니 그만큼은 봐준다
import sys, os, json, re, difflib, statistics
from collections import Counter
import fitz

pdfdir, outdir = sys.argv[1], sys.argv[2]
verbose = '-v' in sys.argv
norm = lambda s: re.sub(r'[\s\x00-\x1f]+', '', s)  # HWP 는 빈칸을 U+0001 로 적기도 한다
# 합자·호환 글자는 같은 것으로 본다(pdf.js 는 ﬁ 를 그대로, 우리는 fi 로 푼다)
import unicodedata
def canon(s):
    s = unicodedata.normalize('NFKC', s)
    return s.replace('­', '').replace('‐', '-').replace('‑', '-').replace('’', "'").replace('‘', "'").replace('“', '"').replace('”', '"')

def bag_pr(ours, ref):
    a, b = Counter(canon(norm(ours))), Counter(canon(norm(ref)))
    if not a and not b: return (1.0, 1.0)  # 둘 다 빈 쪽(백지)
    inter = sum((a & b).values())
    return (inter / max(1, sum(a.values())), inter / max(1, sum(b.values())))  # 정밀도, 재현율

rows = []
for f in sorted(os.listdir(outdir)):
    if not f.endswith('.json') or f.startswith('_'): continue
    rec = json.load(open(os.path.join(outdir, f)))
    name = f[:-5]
    if rec.get('err'):
        rows.append({'doc': name, 'err': rec['err']}); continue
    doc = fitz.open(os.path.join(pdfdir, rec['file']))
    per = []
    for pno, pg in rec['pages'].items():
        page = doc[int(pno) - 1]
        mu_text = page.get_text('text')
        # 글자별 상자 — rawdict
        chars = []
        for b in page.get_text('rawdict')['blocks']:
            for l in b.get('lines', []):
                for s in l['spans']:
                    for c in s['chars']:
                        if c['c'].strip(): chars.append((c['c'], c['origin'][0], c['origin'][1], c['bbox'][0], c['bbox'][2]))
        p_mu, r_mu = bag_pr(pg['oursText'], mu_text)
        p_js, r_js = bag_pr(pg['oursText'], pg.get('pdfjs', ''))
        p_ref, r_ref = bag_pr(pg.get('pdfjs', ''), mu_text)  # 기준끼리
        order = difflib.SequenceMatcher(None, canon(norm(pg['oursText']))[:4000], canon(norm(mu_text))[:4000], autojunk=False).ratio() if mu_text.strip() else 1.0
        # 자리 — 우리 조각을 글자로 편다
        ours_chars = {}
        x0 = pg.get('x0', 0)  # pymupdf 는 CropBox 왼쪽 위가 원점이다
        for text, x, y, w, size in pg['ours']:
            x -= x0
            t = text
            n = max(1, len(t))
            for i, ch in enumerate(t):
                if not ch.strip(): continue
                ours_chars.setdefault(ch, []).append((x + w * i / n, y))
        hit = 0; dxs = []
        for ch, ox, oy, bx0, bx1 in chars:
            cands = ours_chars.get(ch) or ours_chars.get(canon(ch))
            if not cands: continue
            best = None
            for (cx, cy) in cands:
                if abs(cy - oy) <= 3 and bx0 - 6 <= cx <= bx1 + 6:
                    d = abs(cx - bx0)
                    if best is None or d < best: best = d
            if best is not None: hit += 1; dxs.append(best)
        pos = hit / max(1, len(chars)) if chars else 1.0
        per.append({'page': int(pno), 'p_mu': p_mu, 'r_mu': r_mu, 'p_js': p_js, 'r_js': r_js, 'r_ref': r_ref, 'order': order, 'pos': pos, 'dx': statistics.median(dxs) if dxs else 0, 'n': len(chars)})
    doc.close()
    if not per: continue
    avg = lambda k: sum(x[k] for x in per) / len(per)
    rows.append({'doc': name, 'n': rec.get('n'), 'tagged': rec.get('tagged'), 'ms': rec.get('ms'), 'pages': per,
                 'p_mu': avg('p_mu'), 'r_mu': avg('r_mu'), 'p_js': avg('p_js'), 'r_js': avg('r_js'), 'r_ref': avg('r_ref'), 'order': avg('order'), 'pos': avg('pos'),
                 'worst': min(per, key=lambda x: min(x['r_mu'], x['p_mu'], x['pos']))})

# 점수: 기준끼리의 차이(r_ref)만큼은 봐주고, 그보다 얼마나 더 나쁜가
def score(r):
    if 'err' in r: return -1
    return min(r['r_mu'], r['p_mu'], r['pos'])
rows.sort(key=score)
print(f"{'문서':16} {'쪽':>4} {'재현(mu)':>8} {'정밀(mu)':>8} {'재현(js)':>8} {'기준끼리':>8} {'차례':>6} {'자리':>6} {'ms':>5}  최악 쪽")
for r in rows:
    if 'err' in r: print(f"{r['doc']:16} ERR {r['err']}"); continue
    w = r['worst']
    print(f"{r['doc']:16} {r['n']:>4} {r['r_mu']:8.3f} {r['p_mu']:8.3f} {r['r_js']:8.3f} {r['r_ref']:8.3f} {r['order']:6.3f} {r['pos']:6.3f} {r['ms']:>5}  p{w['page']} 재현{w['r_mu']:.2f} 정밀{w['p_mu']:.2f} 자리{w['pos']:.2f} dx{w['dx']:.1f}")
ok = [r for r in rows if 'err' not in r]
print(f"\n문서 {len(rows)}개 · 오류 {len(rows)-len(ok)} · 평균 재현(mu) {sum(r['r_mu'] for r in ok)/len(ok):.4f} 정밀 {sum(r['p_mu'] for r in ok)/len(ok):.4f} 자리 {sum(r['pos'] for r in ok)/len(ok):.4f} · 기준끼리 {sum(r['r_ref'] for r in ok)/len(ok):.4f}")
json.dump(rows, open(os.path.join(outdir, '_summary.json'), 'w'), ensure_ascii=False)
