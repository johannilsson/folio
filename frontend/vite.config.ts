import { fileURLToPath } from 'node:url'
import { defineConfig } from 'vite'

export default defineConfig({
  build: {
    outDir: 'dist',
    emptyOutDir: true,
    // The page the native preview draws diagrams and colours code with.
    rollupOptions: {
      input: {
        diagram: fileURLToPath(new URL('./diagram.html', import.meta.url)),
      },
    },
  },
})
