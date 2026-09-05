// Node 에서도 도는지 본다.
//
//   node tests/node.mjs [fixtures]
//
// 브라우저 밖에는 Worker 도 createImageBitmap 도 document 도 없다. 그래도
// 뽑기(글자·주석·구조·양식)와 편집(build)은 되어야 한다 — 서버에서 본문을
// 색인하거나 쪽을 골라 다시 내는 쓰임이 이 갈래다. 그리기는 캔버스가 있어야
// 하므로, 없을 때 무슨 일인지 알아들을 오류가 나는지까지 함께 본다.
//
// dist/ 를 읽으므로 build:js 를 먼저 돌려야 한다.
import { readFile } from "node:fs/promises";
import { PDFDocument, PasswordNeeded } from "../dist/index.js";

const FX = (process.argv[2] ?? "tests/fixtures").replace(/\/$/, "");
let ok = 0;
let bad = 0;
const t = (name, cond, got) => {
  if (cond) ok++;
  else { bad++; console.log(`  실패 ${name}${got === undefined ? "" : ` — ${got}`}`); }
};

// 파일 경로로 연다. 브라우저에서는 주소를 fetch 하지만 여기서는 못 한다.
{
  const pdf = await PDFDocument.open(`${FX}/annots.pdf`);
  t("경로로 열기", pdf.pages === 1, pdf.pages);
  const text = await pdf.text(1);
  t("글자 뽑기", text.includes("annots"), JSON.stringify(text.slice(0, 40)));
  const items = await pdf.textItems(1);
  t("덩이 뽑기", items.length > 0 && typeof items[0].dir === "string", items.length);
  const an = await pdf.annotations(1);
  t("주석 뽑기", an.length === 5, an.length);
  t("권한", Object.keys(pdf.permissions).length === 8);
  // 캔버스가 없으면 무슨 일인지 말해 줘야 한다
  let msg = "";
  await pdf.render(1, null).catch((e) => { msg = e.message; });
  t("캔버스 없을 때 안내", /canvas/i.test(msg), JSON.stringify(msg));
  pdf.close();
}

// 바이트로도 연다
{
  const bytes = new Uint8Array(await readFile(`${FX}/annots.pdf`));
  const pdf = await PDFDocument.open(bytes);
  t("바이트로 열기", pdf.pages === 1, pdf.pages);
  // 빈 spec 으로도 다시 낼 수 있어야 한다 — 안 적은 것은 그대로 둔다
  const out = await pdf.build({});
  t("다시 내기", out !== null && out.length > 0, out?.length);
  const again = await PDFDocument.open(out);
  t("낸 것 다시 열기", again.pages === 1, again.pages);
  t("낸 것의 글자", (await again.text(1)).includes("annots"));
  again.close();
  pdf.close();
}

// 태그 구조
{
  const pdf = await PDFDocument.open(`${FX}/struct.pdf`);
  const root = await pdf.structure();
  t("구조 뿌리", root !== null && root.children.length > 0, root?.children.length);
  pdf.close();
}

// 암호가 걸린 문서
{
  const pdf = await PDFDocument.open(`${FX}/enc-perm.pdf`, { password: "" });
  t("잠긴 문서 열기", pdf.pages === 1, pdf.pages);
  t("잠긴 문서 권한", pdf.permissions.print === false);
  pdf.close();
}

// 없는 파일은 조용히 넘어가면 안 된다
{
  let msg = "";
  await PDFDocument.open(`${FX}/없는파일.pdf`).catch((e) => { msg = e.message; });
  t("없는 파일", msg.length > 0, JSON.stringify(msg));
}

// 닫은 뒤에 부르면 매달리지 않고 바로 오류
{
  const pdf = await PDFDocument.open(`${FX}/annots.pdf`);
  pdf.close();
  let msg = "";
  await pdf.text(1).catch((e) => { msg = e.message; });
  t("닫은 뒤 부르기", /closed/.test(msg), JSON.stringify(msg));
}

// 암호를 걸어 낸 뒤 암호 없이 열면 PasswordNeeded
{
  const pdf = await PDFDocument.open(`${FX}/annots.pdf`);
  const sealed = await pdf.build({ encryptPw: "열쇠" });
  pdf.close();
  t("암호 걸어 내기", sealed !== null && sealed.length > 0, sealed?.length);
  let kind = "";
  await PDFDocument.open(sealed.slice()).catch((e) => { kind = e.constructor.name; });
  t("암호 필요", kind === "PasswordNeeded", kind);
  const back = await PDFDocument.open(sealed.slice(), { password: "열쇠" });
  t("암호 주고 열기", back.pages === 1, back.pages);
  back.close();
  void PasswordNeeded;
}

// 문서 두 개를 한꺼번에 — 워커가 없으면 모듈 하나를 나눠 쓰므로, 문서마다
// 제 엔진 사례를 들지 않으면 뒤엣것이 앞엣것을 덮어쓴다. 실제로 그랬다:
// 5쪽짜리를 열어 둔 채 1쪽짜리를 열면 5쪽짜리의 글자가 1쪽짜리 것으로 나왔다.
{
  const A = await PDFDocument.open(`${FX}/multi.pdf`);
  const B = await PDFDocument.open(`${FX}/annots.pdf`);
  t("둘 다 열림", A.pages === 5 && B.pages === 1, `${A.pages}/${B.pages}`);
  t("앞 문서가 안 덮인다", (await A.text(1)).includes("PAGE 1"), JSON.stringify((await A.text(1)).slice(0, 20)));
  t("뒤 문서도 제 것", (await B.text(1)).includes("annots"));
  // 번갈아 불러도 섞이지 않아야 한다
  const [a2, b1, a3] = await Promise.all([A.text(2), B.text(1), A.text(3)]);
  t("섞어 불러도 제 것", a2.includes("PAGE 2") && b1.includes("annots") && a3.includes("PAGE 3"),
    `${a2.slice(0, 12)} | ${b1.slice(0, 8)} | ${a3.slice(0, 12)}`);
  // 만들어 낸 것도 제 문서여야 한다
  const out = await A.build({});
  const back = await PDFDocument.open(out.slice());
  t("만든 것이 앞 문서", back.pages === 5, back.pages);
  back.close();
  A.close();
  B.close();
}

// 쪽이 너무 많으면 잘랐다고 알린다.
//
// 같은 쪽을 여러 번 가리키는 정도로는 안 잘린다(파일 크기로 천장을 잡으므로
// 늘 넉넉하다). 잘리는 건 쪽 나무가 저를 다시 가리켜 쪽 수가 파일 크기와
// 상관없이 불어나는 문서다 — 그런 것에 끝까지 매달리지 않으려는 천장이다.
{
  const kids = (n, ref) => Array(n).fill(`${ref} 0 R`).join(" ");
  const bomb = [
    "%PDF-1.7",
    "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj",
    `2 0 obj\n<< /Type /Pages /Count 400 /Kids [${kids(20, 3)}] >>\nendobj`,
    `3 0 obj\n<< /Type /Pages /Count 20 /Kids [${kids(20, 4)}] >>\nendobj`,
    "4 0 obj\n<< /Type /Page /Parent 3 0 R /MediaBox [0 0 200 200] >>\nendobj",
    "trailer\n<< /Size 5 /Root 1 0 R >>", "%%EOF", "",
  ].join("\n");
  const many = await PDFDocument.open(new TextEncoder().encode(bomb));
  t("쪽이 넘치면 알린다", many.truncated === true && many.pages > 0, `${many.pages}쪽 truncated=${many.truncated}`);
  many.close();
}

// 같은 쪽을 여러 번 가리키는 문서는 잘리지 않는다
{
  const rep = [
    "%PDF-1.7",
    "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj",
    `2 0 obj\n<< /Type /Pages /Count 300 /Kids [${Array(300).fill("4 0 R").join(" ")}] >>\nendobj`,
    "4 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] >>\nendobj",
    "trailer\n<< /Size 5 /Root 1 0 R >>", "%%EOF", "",
  ].join("\n");
  const d = await PDFDocument.open(new TextEncoder().encode(rep));
  t("같은 쪽 300번: 다 센다", d.pages === 300 && d.truncated === false, `${d.pages}쪽 truncated=${d.truncated}`);
  d.close();
}

// 캔버스를 주면 Node 에서도 그린다 (@napi-rs/canvas 가 있을 때만 본다)
{
  let createCanvas = null;
  try { ({ createCanvas } = await import("@napi-rs/canvas")); } catch { /* 없으면 건너뛴다 */ }
  if (createCanvas) {
    const pdf = await PDFDocument.open(`${FX}/tile.pdf`);
    const cv = createCanvas(10, 10);
    const r = await pdf.render(1, cv, { scale: 1, dpr: 1 });
    const d = cv.getContext("2d").getImageData(0, 0, cv.width, cv.height).data;
    let inked = 0;
    for (let i = 0; i < d.length; i += 4) if (d[i + 3] > 0 && d[i] < 200) inked++;
    // 브라우저에서 같은 문서를 같은 배율로 그리면 25235 칸이 찍힌다.
    // 무늬·도형은 글꼴과 무관하므로 Node 에서도 같아야 한다.
    t("Node 에서 그리기", Math.abs(inked - 25235) < 500, `${cv.width}x${cv.height} 잉크 ${inked}`);
    t("그리며 글자 자리도 준다", Array.isArray(r.runs), typeof r.runs);
    pdf.close();

    // 새 견본으로 잡은 셋 — 색과 그림이 규격대로 나오는가.
    //
    // 기대값은 poppler 가 같은 크기로 그려 낸 값이다. 셋 다 예전에는
    // 어긋났다: /Decode [1 0] 을 무시했고, 2·4비트 회색 그림을 통째로
    // 안 그렸고, Separation 은 잉크 변환 함수를 안 태우고 회색으로 칠했다.
    {
      const px = async (name, x, y) => {
        const d2 = await PDFDocument.open(`${FX}/${name}`);
        const c2 = createCanvas(10, 10);
        await d2.render(1, c2, { scale: 1, dpr: 1 });
        const g2 = c2.getContext("2d").getImageData(0, 0, c2.width, c2.height).data;
        const i = (y * c2.width + x) * 4;
        const v = [g2[i], g2[i + 1], g2[i + 2]];
        d2.close();
        return v;
      };
      const near = (a, b2, tol = 12) => a.every((v, i) => Math.abs(v - b2[i]) <= tol);
      const dec = await px("t-decode.pdf", 130, 60);
      t("/Decode [1 0] 이 값을 뒤집는다", near(dec, [225, 225, 225]), dec.join(","));
      const two = await px("t-bpc.pdf", 25, 60);
      const four = await px("t-bpc.pdf", 130, 60);
      t("2비트 회색 그림을 그린다", near(two, [0, 0, 0]), two.join(","));
      t("4비트 회색 그림을 그린다", near(four, [170, 170, 170]), four.join(","));
      // 무색 무늬(/PaintType 2)는 칸 안에 색이 없다 — scn 이 준 색으로
      // 그려야 한다. 안 그러면 늘 같은 회색으로 나온다.
      const u1 = await px("t-uncolored.pdf", 20, 50);
      const u2 = await px("t-uncolored.pdf", 150, 50);
      t("무색 무늬가 준 색으로 그려진다",
        u1[0] > 150 && u1[1] < 120 && u1[2] < 120 && u2[2] > 150 && u2[0] < 120,
        `${u1.join(",")} / ${u2.join(",")}`);
      // 혼합 모드 — 이름을 앞머리만 보고 계속 돌아 /ColorDodge 가 뒤의
      // "Color" 에도 걸렸다. 마지막 것이 이겨 캔버스가 모르는 값이 되고,
      // 결국 안 섞인 채 그려졌다.
      const dodge = await px("t-blend.pdf", 126, 62);
      const burn = await px("t-blend.pdf", 174, 62);
      t("ColorDodge 가 섞인다", near(dodge, [0, 191, 84], 20), dodge.join(","));
      t("ColorBurn 이 섞인다", near(burn, [0, 0, 0], 20), burn.join(","));
      // 그림자의 /Extend — 늘이지 말라면 축 밖은 안 칠해야 한다.
      // 엔진이 ext0·ext1 을 보내는데도 그리는 쪽이 안 읽어 늘 늘였다.
      const exOut = await px("u-axial.pdf", 30, 90);
      const exIn = await px("u-axial.pdf", 80, 90);
      t("/Extend false 면 축 밖을 안 칠한다", near(exOut, [255, 255, 255]), exOut.join(","));
      t("/Extend false 라도 축 안은 칠한다", exIn[0] > 120 && exIn[2] > 40, exIn.join(","));

      // 인라인 그림의 줄임 필터 — /AHx 를 안 풀어 글자 코드가 화소가 됐다
      const ah = await px("u-inline.pdf", 30, 30);
      const ah2 = await px("u-inline.pdf", 70, 50);
      t("인라인 /AHx 를 푼다", near(ah, [0, 0, 0], 20) && near(ah2, [191, 191, 191], 20),
        `${ah.join(",")} / ${ah2.join(",")}`);

      // /CalRGB — 감마·행렬을 거쳐 XYZ 로 간 뒤 화면 색이 된다. 여태
      // DeviceRGB 로 봐서 우리만 딴 색이었다(pdf.js·poppler 는 일치).
      // 채우기와 셰이딩 두 길 모두 봐야 한다 — 셰이딩만 남아 있었다.
      const cal1 = await px("v-cal.pdf", 50, 30);
      const calSh = await px("v-cal.pdf", 40, 120);
      t("CalRGB 채우기가 옮겨진다", near(cal1, [255, 0, 60], 8), cal1.join(","));
      t("CalRGB 셰이딩도 옮겨진다", near(calSh, [0, 250, 119], 8), calSh.join(","));

      // 16비트 그림 — 2·4비트와 같은 이유로 날 갈래에 길이 없었다
      const b16 = await px("v-bpc16.pdf", 30, 60);
      t("16비트 그림을 그린다", near(b16, [136, 136, 136], 8), b16.join(","));

      const s1 = await px("t-sep.pdf", 50, 50);
      const s2 = await px("t-sep.pdf", 150, 50);
      t("Separation 이 잉크 변환 함수를 탄다", near(s1, [209, 224, 245]) && near(s2, [48, 117, 209]),
        `${s1.join(",")} / ${s2.join(",")}`);
    }

    // 문서를 잇달아 열어도 앞 문서의 그림이 안 나오는가.
    //
    // 엔진 인스턴스는 문서끼리 나눠 쓴다(Node 에서는 모듈 하나). 스텐실
    // (1비트 마스크) 캔버스 열쇠가 `s{쪽}-{칸}` 뿐이라, 크기가 같은 두
    // 문서의 같은 자리가 같은 열쇠가 되어 앞 문서 그림이 그려졌다.
    // jb-arith 를 열고 jb-half 를 열면 jb-arith 가 나왔다.
    {
      const inkOf = async (name) => {
        const d2 = await PDFDocument.open(`${FX}/${name}`);
        const c2 = createCanvas(10, 10);
        await d2.render(1, c2, { scale: 1, dpr: 1 });
        const px = c2.getContext("2d").getImageData(0, 0, c2.width, c2.height).data;
        let n = 0;
        for (let i = 0; i < px.length; i += 4) if (px[i] < 128) n++;
        d2.close();
        return n * 100 / (c2.width * c2.height);
      };
      const a1 = await inkOf("jb-arith.pdf");
      const h1 = await inkOf("jb-half.pdf");
      const p1 = await inkOf("jb-page1.pdf");
      const a2 = await inkOf("jb-arith.pdf");
      t("잇달아 열어도 앞 문서 그림이 안 섞인다",
        Math.abs(a1 - 10.5) < 0.6 && Math.abs(h1 - 15.8) < 0.6
        && Math.abs(p1 - 28.2) < 0.6 && Math.abs(a2 - 10.5) < 0.6,
        `arith ${a1.toFixed(1)} · half ${h1.toFixed(1)} · page1 ${p1.toFixed(1)} · arith ${a2.toFixed(1)}`);
    }

    // 그림도 그린다.
    //
    // 예전에는 Node 에 createImageBitmap 이 없다는 이유로 그림 자리를 통째로
    // 비웠다. 그래서 스캔 문서(글자가 없고 사진만 있는 문서)가 흰 종이로
    // 나왔다 — 견본 123개 중 19개가 그랬다. 이제 날 화소로 넘겨 캔버스에
    // 얹고, JPEG 은 엔진이 푼다.
    // 기대치는 브라우저에서 같은 크기로 그려 나온 값이다. 작은 것(가리개
    // 견본 32칸)까지 그대로여야 "브라우저와 같다" 고 말할 수 있다.
    //
    // scan4 는 50000 이었다. 그림 키울 때 뭉개기를 고치면서(11ad2b4) 값이
    // 바뀌었는데 dist/ 가 git 밖이라 낡은 빌드로 시험이 돌아 여태 안 걸렸다.
    // 다시 재니 브라우저 34568, Node 34568 로 같다 — 둘이 어긋난 게 아니라
    // 기대치가 낡았던 것이다.
    for (const [name, least] of [["scan4.pdf", 34000], ["cmyk.pdf", 6900],
                                 ["indexed.pdf", 14000], ["jpx-53.pdf", 16000],
                                 ["mask-stencil.pdf", 30], ["bpc16.pdf", 26]]) {
      const p2 = await PDFDocument.open(`${FX}/${name}`);
      const c2 = createCanvas(400, 520);
      await p2.render(1, c2);
      const px = c2.getContext("2d").getImageData(0, 0, 400, 520).data;
      let ink = 0;
      for (let i = 0; i < px.length; i += 4)
        if (px[i + 3] > 8 && (px[i] < 240 || px[i + 1] < 240 || px[i + 2] < 240)) ink++;
      t(`Node 그림: ${name}`, ink >= least, `잉크 ${ink} (적어도 ${least})`);
      p2.close();
    }

    // 프로그레시브 JPEG.
    //
    // 한 블록을 한 번에 담지 않고, 훑기를 나눠 DC 부터 성기게 담았다가
    // 아랫자리를 채워 간다. 흐린 그림이 또렷해지는 그 방식이다. 예전에는
    // 이걸 만나면 자리만 비웠다. 같은 그림을 베이스라인으로도 넣어 두고
    // 둘이 **똑같이** 나오는지 본다 — 다르면 어느 한쪽이 틀린 것이다.
    {
      const shot = async (n) => {
        const q = await PDFDocument.open(`${FX}/${n}.pdf`);
        const c3 = createCanvas(160, 120);
        await q.render(1, c3);
        const d3 = c3.getContext("2d").getImageData(0, 0, 160, 120).data;
        let ink = 0;
        const sum = [0, 0, 0];
        for (let i = 0; i < d3.length; i += 4) {
          if (d3[i] < 240 || d3[i + 1] < 240 || d3[i + 2] < 240) ink++;
          sum[0] += d3[i]; sum[1] += d3[i + 1]; sum[2] += d3[i + 2];
        }
        q.close();
        return { ink, avg: sum.map((v) => Math.round(v / (d3.length / 4))).join(",") };
      };
      const base = await shot("jpg-base");
      const prog = await shot("jpg-prog");
      const gray = await shot("jpg-prog-gray");
      t("프로그레시브: 베이스라인과 같다",
        prog.ink === base.ink && prog.avg === base.avg,
        `프로그레시브 ${prog.ink}/${prog.avg} · 베이스라인 ${base.ink}/${base.avg}`);
      t("프로그레시브: 빈 그림이 아니다", prog.ink > 8000, prog.ink);
      t("프로그레시브 흑백도", gray.ink > 8000 && /^(\d+),\1,\1$/.test(gray.avg),
        `${gray.ink} ${gray.avg}`);

      // 색차를 늘리는 방식이 libjpeg 과 같은지 화소로 본다.
      //
      // JPEG 은 색을 절반으로 줄여 담는다(4:2:0). 늘릴 때 가장 가까운 값을
      // 쓰면 색 경계가 계단처럼 각져, 아래 기준값과 최대 62 까지 벌어졌다.
      // 네 이웃을 섞으면(쌍선형) 5 안으로 들어온다. 기준값은 같은 JPEG 을
      // PIL(libjpeg)로 푼 것이다.
      const want = [[5, 5, 245, 252, 244], [40, 35, 220, 30, 40], [115, 55, 30, 90, 220],
                    [80, 95, 20, 160, 61], [155, 10, 249, 250, 244], [20, 110, 69, 144, 87],
                    [159, 119, 249, 250, 244], [75, 60, 253, 247, 249]];
      const q4 = await PDFDocument.open(`${FX}/jpg-prog.pdf`);
      const c4 = createCanvas(160, 120);
      await q4.render(1, c4);
      const d4 = c4.getContext("2d").getImageData(0, 0, 160, 120).data;
      let worst = 0;
      let where = "";
      for (const [x, y, r, g, b] of want) {
        const at = (y * 160 + x) * 4;
        for (const [k, v] of [[0, r], [1, g], [2, b]]) {
          const dv = Math.abs(d4[at + k] - v);
          if (dv > worst) { worst = dv; where = `[${x},${y}] ${d4[at]},${d4[at + 1]},${d4[at + 2]} vs ${r},${g},${b}`; }
        }
      }
      t("색차 늘리기가 libjpeg 과 맞는다", worst <= 6, `최대차 ${worst} ${where}`);
      q4.close();

      // ICC 색 프로파일.
      //
      // /ICCBased 는 "이 CMYK 값은 이 프로파일 기준이다" 라고 알려 준다.
      // 그걸 안 쓰고 (255-c)(255-k)/255 로 넘기던 때는 littleCMS 가 낸
      // 참값과 평균 53/255, 마젠타는 129 까지 벌어졌다 — 참값 #D7157E
      // 자리에 형광 마젠타 #FF00FF 를 찍었다. 아래 참값은 같은 프로파일로
      // littleCMS 가 낸 것이다.
      const want2 = [[255, 255, 255], [26, 26, 26], [0, 164, 219], [215, 21, 126], [255, 241, 8], [25, 94, 157], [172, 40, 52], [102, 120, 122]];
      const q5 = await PDFDocument.open(`${FX}/icc.pdf`);
      const c5 = createCanvas(200, 150);
      await q5.render(1, c5);
      const d5 = c5.getContext("2d").getImageData(0, 0, 200, 150).data;
      let far = 0;
      let far2 = "";
      for (let i = 0; i < want2.length; i++) {
        const x = 10 + (i % 4) * 45 + 20;
        const yPdf = 100 - Math.floor(i / 4) * 45 + 20;
        const at5 = ((150 - yPdf) * 200 + x) * 4;
        for (let k = 0; k < 3; k++) {
          const dv = Math.abs(d5[at5 + k] - want2[i][k]);
          if (dv > far) { far = dv; far2 = `${i}번 ${d5[at5]},${d5[at5+1]},${d5[at5+2]} vs ${want2[i]}`; }
        }
      }
      t("ICC 색이 littleCMS 와 맞는다", far <= 5, `최대차 ${far} ${far2}`);
      q5.close();

      // CMYK 그림.
      //
      // 성분이 넷인 그림을 셋으로 읽어 화소가 통째로 밀렸다 — 시안이
      // 빨강(249,0,6)으로, 검정이 초록(0,255,0)으로 나왔다. 네 화소짜리
      // 그림(시안·마젠타·노랑·검정)으로 지킨다.
      const pick = async (n) => {
        const q6 = await PDFDocument.open(`${FX}/${n}.pdf`);
        const c6 = createCanvas(80, 20);
        await q6.render(1, c6);
        const d6 = c6.getContext("2d").getImageData(0, 0, 80, 20).data;
        const at6 = (x) => { const i = (10 * 80 + x) * 4; return [d6[i], d6[i + 1], d6[i + 2]]; };
        q6.close();
        return [at6(10), at6(30), at6(50), at6(70)];
      };
      const near = (a, b, tol) => a.every((v, i) => Math.abs(v - b[i]) <= tol);
      // 프로파일이 없는 DeviceCMYK. 규격이 적어 둔 1-min(1,C+K) 를 그대로
      // 쓰면 시안이 (0,255,255) 네온으로 나온다 — 잉크로 찍은 시안은 그런
      // 색이 아니고, 실제 뷰어는 다들 인쇄를 맞춘 근사를 쓴다. 예전에는 이
      // 시험이 네온값을 지키고 있어서 결함이 통과로 굳어 있었다.
      const plain = await pick("img-cmyk");
      t("CMYK 그림: 시안이 인쇄한 시안 색이다", near(plain[0], [0, 184, 241], 10), plain[0]);
      t("CMYK 그림: 검정이 인쇄한 검정 색이다", near(plain[3], [43, 46, 52], 10), plain[3]);
      const iccImg = await pick("img-icc");
      t("CMYK 그림 + ICC: 마젠타", near(iccImg[1], [215, 21, 126], 10), iccImg[1]);
      t("CMYK 그림 + ICC: 검정", near(iccImg[3], [26, 26, 26], 10), iccImg[3]);
    }
  }
}

console.log(`Node  통과 ${ok} · 실패 ${bad}`);
process.exit(bad === 0 ? 0 : 1);
