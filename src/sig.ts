// PDF 전자 서명 확인.
//
// wasm 쪽이 서명 딕셔너리에서 /ByteRange 와 PKCS#7 뭉치를 꺼내 준다. 여기서는
// 그 뭉치를 뜯어 세 가지를 본다.
//
//   1. 서명이 문서 전체를 덮는가 — /ByteRange 뒤에 덧붙은 고침이 있으면 아니다
//   2. 서명 안에 적힌 요약값이 실제 바이트의 요약값과 같은가
//   3. 인증서의 공개 열쇠로 서명이 맞아떨어지는가
//
// 셋이 다 맞아도 "이 인증서를 믿을 만한가" 는 다른 문제다. 그건 뿌리 인증서
// 목록이 있어야 하는 일이라 여기서는 다루지 않고, 서명자 이름만 보여 준다.
// 브라우저에 이미 서명 검증기가 있으므로 큰 수 셈은 WebCrypto 에 맡긴다.

type TLV = { tag: number; hlen: number; len: number; start: number; end: number };

/** 한 조각을 읽는다. start 는 속살이 시작하는 자리다. */
function tlv(b: Uint8Array, p: number): TLV | null {
  if (p + 2 > b.length) return null;
  const tag = b[p];
  let q = p + 1;
  let len = b[q++];
  if (len & 0x80) {
    const n = len & 0x7f;
    if (n === 0 || n > 4 || q + n > b.length) return null;
    len = 0;
    for (let i = 0; i < n; i++) len = len * 256 + b[q++];
  }
  if (q + len > b.length) return null;
  return { tag, hlen: q - p, len, start: q, end: q + len };
}

/** 속살을 조각들로 나눈다. */
function kids(b: Uint8Array, t: TLV): TLV[] {
  const out: TLV[] = [];
  let p = t.start;
  while (p < t.end) {
    const k = tlv(b, p);
    if (!k) break;
    out.push(k);
    p = k.end;
  }
  return out;
}

/** OID 를 점 찍은 글로 옮긴다. */
function oid(b: Uint8Array, t: TLV): string {
  if (t.len === 0) return "";
  const first = b[t.start];
  const parts = [Math.floor(first / 40), first % 40];
  let v = 0;
  for (let i = t.start + 1; i < t.end; i++) {
    v = v * 128 + (b[i] & 0x7f);
    if ((b[i] & 0x80) === 0) { parts.push(v); v = 0; }
  }
  return parts.join(".");
}

const HASH: Record<string, string> = {
  "1.3.14.3.2.26": "SHA-1",
  "2.16.840.1.101.3.4.2.1": "SHA-256",
  "2.16.840.1.101.3.4.2.2": "SHA-384",
  "2.16.840.1.101.3.4.2.3": "SHA-512",
  // 서명 알고리즘에 요약값이 함께 적힌 꼴
  "1.2.840.113549.1.1.5": "SHA-1",
  "1.2.840.113549.1.1.11": "SHA-256",
  "1.2.840.113549.1.1.12": "SHA-384",
  "1.2.840.113549.1.1.13": "SHA-512",
  "1.2.840.10045.4.3.2": "SHA-256",
  "1.2.840.10045.4.3.3": "SHA-384",
  "1.2.840.10045.4.3.4": "SHA-512",
};
const CURVE: Record<string, string> = {
  "1.2.840.10045.3.1.7": "P-256",
  "1.3.132.0.34": "P-384",
  "1.3.132.0.35": "P-521",
};
const OID_MSGDIGEST = "1.2.840.113549.1.9.4";
const OID_CN = "2.5.4.3";
const OID_O = "2.5.4.10";

export type SigCheck = {
  /** 셋 다 맞았는가 */
  ok: boolean;
  /** 서명 안의 요약값과 실제 바이트의 요약값이 같은가 */
  digestOk: boolean;
  /** 공개 열쇠로 서명이 맞아떨어지는가 */
  cryptoOk: boolean;
  /** 서명이 문서 끝까지 덮는가 */
  covers: boolean;
  signer: string;
  issuer: string;
  from: string;
  to: string;
  hash: string;
  algo: string;
  note: string;
};

/** 이름(Name)에서 한 갈래를 뽑는다. */
function nameOf(b: Uint8Array, t: TLV, want: string): string {
  for (const rdn of kids(b, t)) {
    for (const atv of kids(b, rdn)) {
      const kk = kids(b, atv);
      if (kk.length < 2) continue;
      if (oid(b, kk[0]) !== want) continue;
      return new TextDecoder().decode(b.subarray(kk[1].start, kk[1].end));
    }
  }
  return "";
}

/** UTCTime/GeneralizedTime 을 사람이 읽는 꼴로. */
function timeOf(b: Uint8Array, t: TLV): string {
  const s = new TextDecoder().decode(b.subarray(t.start, t.end));
  const m = /^(\d{2})?(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})/.exec(s);
  if (!m) return s;
  const yy = t.tag === 0x17 ? (Number(m[2]) < 50 ? 2000 : 1900) + Number(m[2]) : Number(m[1] + m[2]);
  return `${yy}-${m[3]}-${m[4]}`;
}

/** DER 로 적힌 ECDSA 서명을 r‖s 날바이트로 편다. */
function ecdsaRaw(b: Uint8Array, sig: Uint8Array, size: number): Uint8Array | null {
  const t = tlv(sig, 0);
  if (!t) return null;
  const [r, s] = kids(sig, t);
  if (!r || !s) return null;
  const out = new Uint8Array(size * 2);
  const put = (v: TLV, at: number) => {
    let from = v.start;
    let n = v.len;
    while (n > size && sig[from] === 0) { from++; n--; }
    if (n > size) return false;
    out.set(sig.subarray(from, from + n), at + size - n);
    return true;
  };
  return put(r, 0) && put(s, size) ? out : null;
}

const same = (a: Uint8Array, b: Uint8Array) =>
  a.length === b.length && a.every((v, i) => v === b[i]);

/**
 * 서명 하나를 확인한다.
 *
 * file 은 원본 바이트 그대로여야 한다 — /ByteRange 가 그 자리를 가리킨다.
 */
export async function checkSignature(
  file: Uint8Array,
  der: Uint8Array,
  range: number[],
  covers: boolean,
): Promise<SigCheck> {
  const out: SigCheck = {
    ok: false, digestOk: false, cryptoOk: false, covers,
    signer: "", issuer: "", from: "", to: "", hash: "", algo: "", note: "",
  };
  const fail = (why: string) => { out.note = why; return out; };

  // 서명 대상 바이트 — 구멍 앞뒤를 이어 붙인다
  if (range.length < 4) return fail("바이트 범위가 없습니다");
  const [a, la, c, lc] = range;
  if (a + la > file.length || c + lc > file.length) return fail("바이트 범위가 파일 밖을 가리킵니다");
  const signed = new Uint8Array(la + lc);
  signed.set(file.subarray(a, a + la), 0);
  signed.set(file.subarray(c, c + lc), la);

  // PKCS#7 뜯기
  const root = tlv(der, 0);
  if (!root) return fail("뭉치를 읽지 못했습니다");
  const rk = kids(der, root);
  const wrap = rk.find((k) => k.tag === 0xa0);
  if (!wrap) return fail("SignedData 가 없습니다");
  const sd = tlv(der, wrap.start);
  if (!sd) return fail("SignedData 가 깨졌습니다");
  const sdk = kids(der, sd);
  const certsBag = sdk.find((k) => k.tag === 0xa0);
  // SignedData 안의 SET 은 둘이다 — 앞의 것은 요약 알고리즘 목록,
  // 마지막 것이 서명자 정보다.
  const siSet = sdk.filter((k) => k.tag === 0x31).pop();
  if (!siSet) return fail("서명자 정보가 없습니다");
  const si = kids(der, siSet)[0];
  if (!si) return fail("서명자 정보가 비었습니다");
  const sik = kids(der, si);

  // [version, sid, digestAlgorithm, (A0 signedAttrs), sigAlgorithm, signature, (A1)]
  const digAlg = sik[2];
  const hashName = HASH[oid(der, kids(der, digAlg)[0])] ?? "SHA-256";
  out.hash = hashName;
  const attrs = sik.find((k) => k.tag === 0xa0);
  const after = sik.filter((k) => k.start > (attrs ?? digAlg).end);
  const sigAlgSeq = after.find((k) => k.tag === 0x30);
  const sigVal = after.find((k) => k.tag === 0x04);
  if (!sigAlgSeq || !sigVal) return fail("서명 값이 없습니다");
  const sigOid = oid(der, kids(der, sigAlgSeq)[0]);

  // 요약값 맞대기
  const dig = new Uint8Array(await crypto.subtle.digest(hashName, signed));
  let toVerify = signed;
  if (attrs) {
    let found: Uint8Array | null = null;
    for (const at of kids(der, attrs)) {
      const kk = kids(der, at);
      if (kk.length < 2 || oid(der, kk[0]) !== OID_MSGDIGEST) continue;
      const v = kids(der, kk[1])[0];
      if (v) found = der.subarray(v.start, v.end);
    }
    if (!found) return fail("요약값 항목이 없습니다");
    out.digestOk = same(dig, found);
    // 서명은 서명 속성 뭉치에 대해 만든다. 담길 때는 [0] 이지만 서명할
    // 때는 SET(0x31) 꼴이라, 첫 바이트만 바꿔 다시 만든다.
    const buf = der.slice(attrs.start - attrs.hlen, attrs.end);
    buf[0] = 0x31;
    toVerify = buf;
  } else {
    // 속성 없이 내용에 바로 서명한 꼴
    out.digestOk = true;
  }

  // 인증서
  let spki: Uint8Array | null = null;
  let curve = "";
  if (certsBag) {
    const cert = kids(der, certsBag)[0];
    if (cert) {
      const tbs = kids(der, cert)[0];
      const tk = kids(der, tbs);
      const base = tk[0]?.tag === 0xa0 ? 1 : 0;
      const issuer = tk[base + 2];
      const validity = tk[base + 3];
      const subject = tk[base + 4];
      const spkiT = tk[base + 5];
      if (subject) {
        const cn = nameOf(der, subject, OID_CN);
        const o = nameOf(der, subject, OID_O);
        out.signer = o && cn ? `${cn} (${o})` : cn || o;
      }
      if (issuer) out.issuer = nameOf(der, issuer, OID_CN);
      if (validity) {
        const vv = kids(der, validity);
        if (vv[0]) out.from = timeOf(der, vv[0]);
        if (vv[1]) out.to = timeOf(der, vv[1]);
      }
      if (spkiT) {
        spki = der.slice(spkiT.start - spkiT.hlen, spkiT.end);
        const alg = kids(der, spkiT)[0];
        const ap = alg && kids(der, alg)[1];
        if (ap && ap.tag === 0x06) curve = CURVE[oid(der, ap)] ?? "";
      }
    }
  }
  if (!spki) return fail("인증서를 찾지 못했습니다");

  // 서명 맞추기
  try {
    const val = der.subarray(sigVal.start, sigVal.end);
    if (sigOid.startsWith("1.2.840.10045")) {
      out.algo = `ECDSA ${curve || "?"}`;
      const size = curve === "P-384" ? 48 : curve === "P-521" ? 66 : 32;
      const raw = ecdsaRaw(der, val, size);
      if (!raw) return fail("ECDSA 서명 값을 읽지 못했습니다");
      const key = await crypto.subtle.importKey("spki", spki as BufferSource,
        { name: "ECDSA", namedCurve: curve || "P-256" }, false, ["verify"]);
      out.cryptoOk = await crypto.subtle.verify({ name: "ECDSA", hash: hashName }, key,
        raw as BufferSource, toVerify as BufferSource);
    } else if (sigOid === "1.2.840.113549.1.1.10") {
      out.algo = "RSA-PSS";
      const key = await crypto.subtle.importKey("spki", spki as BufferSource,
        { name: "RSA-PSS", hash: hashName }, false, ["verify"]);
      const salt = hashName === "SHA-512" ? 64 : hashName === "SHA-384" ? 48 : 32;
      out.cryptoOk = await crypto.subtle.verify({ name: "RSA-PSS", saltLength: salt }, key,
        val as BufferSource, toVerify as BufferSource);
    } else {
      out.algo = "RSA PKCS#1 v1.5";
      const key = await crypto.subtle.importKey("spki", spki as BufferSource,
        { name: "RSASSA-PKCS1-v1_5", hash: hashName }, false, ["verify"]);
      out.cryptoOk = await crypto.subtle.verify("RSASSA-PKCS1-v1_5", key,
        val as BufferSource, toVerify as BufferSource);
    }
  } catch (e) {
    return fail(`확인하지 못했습니다: ${String(e)}`);
  }

  out.ok = out.digestOk && out.cryptoOk && out.covers;
  if (!out.digestOk) out.note = "서명한 뒤 내용이 바뀌었습니다";
  else if (!out.cryptoOk) out.note = "서명이 인증서와 맞지 않습니다";
  else if (!out.covers) out.note = "서명 뒤에 덧붙은 고침이 있습니다";
  else out.note = "서명한 그대로입니다";
  return out;
}
