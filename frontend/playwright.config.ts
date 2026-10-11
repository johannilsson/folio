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

// Two files in separate directories (b/ is its own "repo") served as a set, with
// the set manifest kept in the temp dir so the real config is never touched.
const SET_PORT = 7392
const serveSet = [
  'd=$(mktemp -d)',
  'mkdir -p "$d/a" "$d/b/.git" "$d/cfg"',
  `cp ${__dirname}/e2e/fixture.md "$d/a/alpha.md"`,
  `cp ${__dirname}/e2e/second.md "$d/b/beta.md"`,
  // Long enough to scroll, for the scroll-position spec.
  `for i in $(seq 1 150); do printf 'Paragraph %s of the long file.\\n\\n' $i; done > "$d/b/long.md"`,
  'cd "$d"',
  'export FOLIO_CONFIG_DIR="$d/cfg"',
  `${root}/target/debug/folio set add e2e a/alpha.md b/beta.md b/long.md`,
  `exec ${root}/target/debug/folio serve --set e2e --no-open --no-watch -p ${SET_PORT}`,
].join(' && ')

export default defineConfig({
  testDir: './e2e',
  workers: 1,
  reporter: 'list',
  use: { baseURL: `http://127.0.0.1:${PORT}`, viewport: { width: 1280, height: 800 } },
  // Same specs twice: over HTTP, and through the native-app bridge (see e2e/fixtures.ts).
  projects: [
    { name: 'http' },
    { name: 'bridge', use: { bridge: true } },
  ],
  webServer: [
    {
      command: serve,
      url: `http://127.0.0.1:${PORT}/`,
      reuseExistingServer: false,
      timeout: 30_000,
    },
    {
      command: serveSet,
      url: `http://127.0.0.1:${SET_PORT}/`,
      reuseExistingServer: false,
      timeout: 30_000,
    },
  ],
})
