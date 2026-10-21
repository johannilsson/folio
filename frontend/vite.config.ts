import { fileURLToPath } from 'node:url'
import { defineConfig } from 'vitest/config'

export default defineConfig({
  build: {
    outDir: 'dist',
    emptyOutDir: true,
    // The editor page, and the page the native preview draws diagrams with.
    rollupOptions: {
      input: {
        index: fileURLToPath(new URL('./index.html', import.meta.url)),
        diagram: fileURLToPath(new URL('./diagram.html', import.meta.url)),
      },
    },
  },
  test: {
    environment: 'jsdom',
    exclude: ['e2e/**', 'node_modules/**'],
  },
})
