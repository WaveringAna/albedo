import { readFileSync } from 'node:fs';
import { homedir, hostname } from 'node:os';
import { join } from 'node:path';
import { svelte } from '@sveltejs/vite-plugin-svelte';
import { defineConfig, type ProxyOptions } from 'vite';

// In development the page talks to the running daemon through Vite: the proxy
// reads the daemon's port and token the way the CLI does, so the browser never
// holds the token. `albedo web` does the same in production. The endpoint is
// read once, so restart `npm run dev` after the daemon restarts.
function daemonProxy(rewrite: (path: string) => string, answer?: Record<string, string>): ProxyOptions {
  const home = process.env.ALBEDO_HOME ?? join(homedir(), '.albedo');
  const { port, token } = JSON.parse(readFileSync(join(home, 'daemon.json'), 'utf8'));
  return {
    target: `http://127.0.0.1:${port}`,
    headers: { authorization: `Bearer ${token}` },
    rewrite,
    configure(proxy) {
      proxy.on('proxyReq', (req) => {
        req.removeHeader('origin');
        req.removeHeader('cookie');
        req.removeHeader('referer');
      });
      if (answer) proxy.on('proxyRes', (res) => Object.assign(res.headers, answer));
    },
  };
}

// Artifact pages are sandboxed by the same headers `albedo web` sets on its
// /frame route (robot-docs/artifacts.md), so the client is tried as it ships.
const FRAME_HEADERS = {
  'content-security-policy': 'sandbox allow-scripts allow-forms allow-popups allow-popups-to-escape-sandbox allow-modals allow-downloads allow-pointer-lock',
  'access-control-allow-origin': '*',
  'cross-origin-resource-policy': 'cross-origin',
  'referrer-policy': 'no-referrer',
  'x-content-type-options': 'nosniff',
};

function ownNames(): string[] {
  const name = hostname().toLowerCase().replace(/\.local$/, '');
  return [name, `${name}.local`, '.ts.net'];
}

// Only the dev server talks to a daemon, so a build (in the Nix sandbox, say)
// never needs daemon.json.
export default defineConfig(({ command }) => ({
  plugins: [svelte()],
  // Open to the local network, so other devices at home can try the client.
  // Only this machine's own names (and Tailscale's MagicDNS ones) pass as Host:
  // the proxy holds the daemon token, so any name a page could rebind must not.
  server: {
    host: true,
    allowedHosts: ownNames(),
    proxy:
      command === 'serve'
        ? {
            '/api': daemonProxy((path) => path.replace(/^\/api/, '')),
            '/frame/': daemonProxy((path) => path.replace(/^\/frame/, '/extensions/artifacts/frame'), FRAME_HEADERS),
          }
        : undefined,
  },
  build: { target: 'es2022', cssCodeSplit: false, reportCompressedSize: true },
}));
