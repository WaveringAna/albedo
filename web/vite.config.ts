import { randomBytes, timingSafeEqual } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { homedir, networkInterfaces } from 'node:os';
import { join } from 'node:path';
import { svelte } from '@sveltejs/vite-plugin-svelte';
import { defineConfig, type Plugin, type ProxyOptions } from 'vite';

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

// The dev server listens on the network so a phone can try the client, and
// the proxy acts with the daemon's token, so anything but this machine must
// sign in first: each run draws a key, prints a link carrying it, and the
// link trades it for an HttpOnly cookie, the way `albedo web` signs a browser
// in. Without the cookie, /api answers 401 web_signed_out. Requests from this
// machine itself need no key.
function signIn(): Plugin {
  const key = randomBytes(24).toString('hex');
  const COOKIE = 'albedo_dev';
  const matches = (given: string | undefined) => !!given && given.length === key.length && timingSafeEqual(Buffer.from(given), Buffer.from(key));
  return {
    name: 'albedo-dev-sign-in',
    configureServer(server) {
      server.middlewares.use((req, res, next) => {
        const loopback = ['127.0.0.1', '::1', '::ffff:127.0.0.1'].includes(req.socket.remoteAddress ?? '');
        const url = new URL(req.url ?? '/', 'http://dev');
        if (url.pathname === '/' && url.searchParams.has('key')) {
          if (!matches(url.searchParams.get('key') ?? undefined)) {
            res.statusCode = 403;
            return res.end('that key is not this run\'s\n');
          }
          res.statusCode = 303;
          res.setHeader('set-cookie', `${COOKIE}=${key}; Path=/; HttpOnly; SameSite=Strict; Max-Age=2592000`);
          res.setHeader('location', '/');
          return res.end();
        }
        if (!loopback && url.pathname.startsWith('/api')) {
          const cookie = (req.headers.cookie ?? '').split(/;\s*/).find((part) => part.startsWith(`${COOKIE}=`))?.slice(COOKIE.length + 1);
          if (!matches(cookie)) {
            res.statusCode = 401;
            res.setHeader('content-type', 'application/json');
            return res.end(JSON.stringify({ error: { code: 'web_signed_out', detail: 'open the link npm run dev printed' } }));
          }
        }
        next();
      });
      server.httpServer?.once('listening', () => {
        const address = server.httpServer?.address();
        const port = typeof address === 'object' && address ? address.port : 5317;
        const lan = Object.values(networkInterfaces())
          .flat()
          .filter((entry) => entry && entry.family === 'IPv4' && !entry.internal)
          .map((entry) => `http://${entry!.address}:${port}/?key=${key}`);
        for (const link of lan) server.config.logger.info(`  sign in from another device: ${link}`);
      });
    },
  };
}

export default defineConfig({
  plugins: [svelte(), signIn()],
  server: { host: true, proxy: { '/api': daemonProxy() } },
  build: { target: 'es2022', cssCodeSplit: false, reportCompressedSize: true },
});
