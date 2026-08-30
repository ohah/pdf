// 예제 셋(React·Vue·Svelte)을 한 서버에서 띄운다.
//
//   npm i && npm run build:wasm && npx vite examples
//
// 소스를 그대로 물리므로(alias) 고치면 바로 화면에 반영된다. 실제로 쓸
// 때는 "@ohah/pdf" 를 npm 에서 받으면 되고, 이 alias 는 없어도 된다.
import { createReadStream, existsSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import react from "@vitejs/plugin-react";
import vue from "@vitejs/plugin-vue";
import { svelte } from "@sveltejs/vite-plugin-svelte";
import { zntc } from "@zntc/vite-plugin";

const here = dirname(fileURLToPath(import.meta.url));
const repo = resolve(here, "..");

// wasm·cmap·견본 문서는 저장소 안 다른 곳에 있다. 예제용으로만 내어 준다.
const assets = {
  name: "ohah-pdf-assets",
  configureServer(server) {
    server.middlewares.use((req, res, next) => {
      const url = (req.url || "").split("?")[0];
      const file = url === "/pdf.wasm" ? join(repo, "dist/pdf.wasm")
        : url === "/sample.pdf" ? join(repo, "tests/fixtures/korean.pdf")
        : url.startsWith("/cmaps/") ? join(repo, url)
        // 번들러 없이 dist 를 그대로 물리는 vanilla.html 용
        : url.startsWith("/dist/") ? join(repo, url)
        : null;
      if (!file || !existsSync(file)) return next();
      res.setHeader("content-type",
        file.endsWith(".wasm") ? "application/wasm"
        : file.endsWith(".js") ? "text/javascript"
        : file.endsWith(".pdf") ? "application/pdf"
        : "application/octet-stream");
      createReadStream(file).pipe(res);
    });
  },
};

export default {
  root: here,
  // TS·JSX 는 zntc 가 옮긴다 — 꾸러미를 굽는 것과 같은 트랜스파일러다.
  plugins: [zntc(), react(), vue(), svelte(), assets],
  esbuild: false,
  resolve: {
    alias: {
      "@ohah/pdf/react": resolve(repo, "src/react.ts"),
      "@ohah/pdf/vue": resolve(repo, "src/vue.ts"),
      "@ohah/pdf/svelte": resolve(repo, "src/svelte.ts"),
      "@ohah/pdf": resolve(repo, "src/index.ts"),
    },
  },
  build: {
    rollupOptions: {
      input: {
        react: join(here, "react/index.html"),
        vue: join(here, "vue/index.html"),
        svelte: join(here, "svelte/index.html"),
      },
    },
  },
};
