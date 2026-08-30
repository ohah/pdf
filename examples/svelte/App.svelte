<script>
  import { onMount } from "svelte";
  import { pdfStore, pdfPage } from "@ohah/pdf/svelte";

  const pdf = pdfStore({ wasm: "/pdf.wasm", cmaps: "/cmaps" });
  let page = 1;

  const pick = (e) => { page = 1; pdf.open(e.target.files[0]); };

  // 시험용 — ?doc= 이 붙어 있으면 그 문서를 바로 연다
  onMount(async () => {
    const q = new URLSearchParams(location.search).get("doc");
    if (q) pdf.open(new Uint8Array(await (await fetch(q)).arrayBuffer()));
  });
</script>

<div style="font: 14px system-ui; margin: 24px">
  <h1>Svelte</h1>
  <input type="file" accept="application/pdf" on:change={pick} />
  {#if $pdf.loading}<p>여는 중…</p>{/if}
  {#if $pdf.error}<p style="color: crimson">{String($pdf.error)}</p>{/if}
  {#if $pdf.doc}
    <p id="info">
      {$pdf.doc.pages}쪽 중 {page}쪽
      <button on:click={() => (page = Math.max(1, page - 1))}>이전</button>
      <button on:click={() => (page = Math.min($pdf.doc.pages, page + 1))}>다음</button>
    </p>
    <canvas use:pdfPage={{ doc: $pdf.doc, page, scale: 1.2 }} style="border: 1px solid #ddd"></canvas>
  {/if}
</div>
