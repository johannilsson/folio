import { defineConfig } from '@playwright/test'
import { resolve } from 'path'

const PORT = 7391
const root = resolve(__dirname, '..')

// Serves a throwaway copy of the fixture from a temp dir so the sidecar
// (.folio/) never touches the repo.
const serve = [
  'd=$(mktemp -d)',
  `cp ${__dirname}/e2e/fixture.md "$d/fixture.md"`,
  'cd "$d"',
  `exec ${root}/target/debug/folio serve --no-open --no-watch -p ${PORT} fixture.md`,
].join(' && ')

export default defineConfig({
  testDir: './e2e',
  workers: 1,
  reporter: 'list',
  use: { baseURL: `http://127.0.0.1:${PORT}`, viewport: { width: 1280, height: 800 } },
  webServer: {
    command: serve,
    url: `http://127.0.0.1:${PORT}/`,
    reuseExistingServer: false,
    timeout: 30_000,
  },
})
