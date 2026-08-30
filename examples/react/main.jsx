// React 갈래 — usePdf 로 열고 PDFPage 로 그린다.
import { useEffect, useState } from "react";
import { createRoot } from "react-dom/client";
import { usePdf, PDFPage } from "@ohah/pdf/react";

const paths = { wasm: "/pdf.wasm", cmaps: "/cmaps" };

function App() {
  const [src, setSrc] = useState(null);
  const [page, setPage] = useState(1);
  const { doc, loading, error } = usePdf(src, paths);

  // 시험용 — ?doc= 이 붙어 있으면 그 문서를 바로 연다
  useEffect(() => {
    const q = new URLSearchParams(location.search).get("doc");
    if (q) fetch(q).then((r) => r.blob()).then(setSrc);
  }, []);

  return (
    <div style={{ font: "14px system-ui", margin: 24 }}>
      <h1>React</h1>
      <input type="file" accept="application/pdf"
        onChange={(e) => { setSrc(e.target.files[0]); setPage(1); }} />
      {loading && <p>여는 중…</p>}
      {error && <p style={{ color: "crimson" }}>{String(error)}</p>}
      {doc && (
        <>
          <p id="info">
            {doc.pages}쪽 중 {page}쪽{" "}
            <button onClick={() => setPage((p) => Math.max(1, p - 1))}>이전</button>{" "}
            <button onClick={() => setPage((p) => Math.min(doc.pages, p + 1))}>다음</button>
          </p>
          <PDFPage doc={doc} page={page} scale={1.2}
            style={{ border: "1px solid #ddd" }}
            onRender={(r) => { window.__done = { pages: doc.pages, ...r }; }} />
        </>
      )}
    </div>
  );
}

createRoot(document.getElementById("root")).render(<App />);
