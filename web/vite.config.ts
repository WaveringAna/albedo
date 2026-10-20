import { readFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { svelte } from '@sveltejs/vite-plugin-svelte';
import { defineConfig, type ProxyOptions } from 'vite';

// In development the page talks to the running daemon through Vite: the proxy
// reads the daemon's port and token the way the CLI does, so the browser never
// holds the token. `albedo web` does the same in production. The endpoint is
// read once, so restart `npm run dev` after the daemon restarts.
function daemonProxy(): ProxyOptions {
  const home = process.env.ALBEDO_HOME ?? join(homedir(), '.albedo');
  const { port, token } = JSON.parse(readFileSync(join(home, 'daemon.json'), 'utf8'));
  return {
    target: `http://127.0.0.1:${port}`,
    headers: { authorization: `Bearer ${token}` },
    rewrite: (path) => path.replace(/^\/api/, ''),
    configure(proxy) {
      proxy.on('proxyReq', (req) => {
        req.removeHeader('origin');
        req.removeHeader('cookie');
      });
    },
  };
}

// Only the dev server talks to a daemon, so a build (in the Nix sandbox, say)
// never needs daemon.json.
export default defineConfig(({ command }) => ({
  plugins: [svelte()],
  // Open to the local network, so other devices at home can try the client.
  server: { host: true, proxy: command === 'serve' ? { '/api': daemonProxy() } : undefined },
  build: { target: 'es2022', cssCodeSplit: false, reportCompressedSize: true },
}));
