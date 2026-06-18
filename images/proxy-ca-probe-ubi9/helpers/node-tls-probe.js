'use strict';
const http = require('http');
const tls = require('tls');
const { URL } = require('url');

const target = new URL(process.env.TARGET_URL);
const proxyEnv = process.env.HTTPS_PROXY || process.env.https_proxy;
if (!proxyEnv) { console.error('no HTTPS_PROXY'); process.exit(4); }
const proxy = new URL(proxyEnv);
const port = target.port || 443;

const headers = {};
if (proxy.username) {
  const cred = `${decodeURIComponent(proxy.username)}:${decodeURIComponent(proxy.password)}`;
  headers['Proxy-Authorization'] = 'Basic ' + Buffer.from(cred).toString('base64');
}
const req = http.request({
  host: proxy.hostname, port: proxy.port || 80, method: 'CONNECT',
  path: `${target.hostname}:${port}`, headers,
});
req.on('connect', (res, socket) => {
  if (res.statusCode !== 200) { console.error('CONNECT failed: ' + res.statusCode); process.exit(3); }
  const s = tls.connect({ socket, servername: target.hostname }, () => {
    if (s.authorized) { process.stdout.write('authorized'); s.end(); process.exit(0); }
    console.error('TLS not authorized: ' + s.authorizationError); process.exit(2);
  });
  s.on('error', (e) => { console.error('tls error: ' + e.message); process.exit(2); });
});
req.on('error', (e) => { console.error('connect error: ' + e.message); process.exit(3); });
req.setTimeout(15000, () => { console.error('connect timeout'); process.exit(3); });
req.end();
