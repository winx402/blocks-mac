import react from "@vitejs/plugin-react";
import { fileURLToPath } from "node:url";
import { defineConfig } from "vite";

const root = fileURLToPath(new URL(".", import.meta.url));

export default defineConfig({
  plugins: [react()],
  build: {
    ssr: `${root}scripts/render.tsx`,
    outDir: `${root}.static-build`,
    emptyOutDir: true,
    rollupOptions: {
      output: {
        entryFileNames: "render.mjs",
        format: "es",
      },
    },
  },
});
