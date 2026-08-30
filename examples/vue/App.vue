<script setup>
import { onMounted, ref } from "vue";
import { usePdf, PdfPage } from "@ohah/pdf/vue";

const src = ref(null);
const page = ref(1);
const { doc, loading, error } = usePdf(src, { wasm: "/pdf.wasm", cmaps: "/cmaps" });

const pick = (e) => { src.value = e.target.files[0]; page.value = 1; };

// 시험용 — ?doc= 이 붙어 있으면 그 문서를 바로 연다
onMounted(async () => {
  const q = new URLSearchParams(location.search).get("doc");
  if (q) src.value = await (await fetch(q)).blob();
});
</script>

<template>
  <div style="font: 14px system-ui; margin: 24px">
    <h1>Vue 3</h1>
    <input type="file" accept="application/pdf" @change="pick" />
    <p v-if="loading">여는 중…</p>
    <p v-if="error" style="color: crimson">{{ String(error) }}</p>
    <template v-if="doc">
      <p id="info">
        {{ doc.pages }}쪽 중 {{ page }}쪽
        <button @click="page = Math.max(1, page - 1)">이전</button>
        <button @click="page = Math.min(doc.pages, page + 1)">다음</button>
      </p>
      <PdfPage :doc="doc" :page="page" :scale="1.2" style="border: 1px solid #ddd" />
    </template>
  </div>
</template>
