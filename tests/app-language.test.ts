import assert from 'node:assert/strict'
import test from 'node:test'
import { appLanguage, isAppLanguagePath, onRequest, serveAppLanguage } from '../server/app-language'

function request(
  country?: string | null,
  query = '',
  headers: HeadersInit = {},
  method = 'GET',
  path = '/raw/apps-data.json',
) {
  return Object.assign(
    new Request('https://skills-lab.example' + path + query, { headers, method }),
    { cf: { country } },
  )
}

test('App language uses explicit preferences, then mainland China, then English', () => {
  assert.equal(appLanguage(request('CN')), 'zh-cn')
  for (const country of ['US', 'GB', 'HK', 'MO', 'TW', 'XX', 'T1', '', null, undefined]) {
    assert.equal(appLanguage(request(country)), 'en')
  }
  assert.equal(appLanguage(request('CN', '?lang=en', { 'Accept-Language': 'zh-CN' })), 'en')
  assert.equal(appLanguage(request('US', '?lang=zh-CN', { 'Accept-Language': 'en' })), 'zh-cn')
  assert.equal(appLanguage(request('CN', '', { 'Accept-Language': 'en-US,en;q=0.9' })), 'en')
  assert.equal(
    appLanguage(request('US', '', { 'Accept-Language': 'fr, en;q=0.5, zh-CN;q=0.9' })),
    'zh-cn',
  )
  assert.equal(
    appLanguage(request('US', '?lang=fr', { 'Accept-Language': 'zh;q=0, en;q=0.7' })),
    'en',
  )
  assert.equal(
    appLanguage(request('CN', '', { 'Accept-Language': '*;q=0.8, en;q=invalid, zh;q=2' })),
    'zh-cn',
  )
  assert.equal(
    appLanguage(request(undefined, '', { 'CF-IPCountry': 'CN', 'X-Forwarded-For': '1.2.3.4' })),
    'en',
  )
})

test('Language negotiation is limited to App catalogs and metadata', () => {
  for (const path of [
    '/raw/apps-data.json',
    '/raw/catalog-data.json',
    '/raw/apps/demo/_metadata.json',
  ]) {
    assert.equal(isAppLanguagePath(path), true)
  }
  for (const path of [
    '/raw/skills-data.json',
    '/raw/demo/_metadata.json',
    '/raw/apps/demo/launcher.json',
    '/raw/apps/demo/scripts/main.lua',
    '/raw/apps/demo/assets/icon.jpg',
    '/raw/apps/../_metadata.json',
  ]) {
    assert.equal(isAppLanguagePath(path), false)
  }
})

test('Cloudflare requests select static variants without changing package fields', async () => {
  const original = {
    kind: 'app',
    id: 'demo',
    name: 'demo',
    description: 'English',
    files: ['launcher.json', 'scripts/main.lua'],
    totalSize: 123,
  }
  const paths: string[] = []
  const env = {
    ASSETS: {
      async fetch(asset: Request) {
        const path = new URL(asset.url).pathname
        paths.push(path)
        assert.equal(asset.method, 'GET')
        assert.equal(new URL(asset.url).search, '')
        assert.equal(asset.headers.has('If-None-Match'), false)
        assert.equal(asset.headers.has('Range'), false)
        const entry = {
          ...original,
          description: path.includes('/zh-cn/') ? '中文介绍' : original.description,
        }
        return Response.json(path.endsWith('_metadata.json') ? entry : [entry], {
          headers: { ETag: 'old-static-etag', 'Cache-Control': 'public, max-age=86400' },
        })
      },
    },
  }
  for (const country of ['CN', 'US', 'CN', 'HK']) {
    for (const path of [
      '/raw/apps-data.json',
      '/raw/catalog-data.json',
      '/raw/apps/demo/_metadata.json',
    ]) {
      const response = await onRequest({
        request: request(
          country,
          '?unused=1',
          { 'If-None-Match': 'old-static-etag', Range: 'bytes=0-5' },
          'GET',
          path,
        ),
        env,
      })
      const language = country === 'CN' ? 'zh-cn' : 'en'
      assert.equal(paths.at(-1), country === 'CN' ? '/raw/i18n/zh-cn/' + path.slice(5) : path)
      assert.equal(response.status, 200)
      assert.equal(response.headers.get('Content-Language'), language)
      assert.match(response.headers.get('Cache-Control')!, /no-store/)
      assert.equal(response.headers.get('CDN-Cache-Control'), 'no-store')
      assert.equal(response.headers.get('Vary'), 'Accept-Language')
      assert.equal(
        response.headers.get('Access-Control-Allow-Origin'),
        'https://simulator.esp-claw.com',
      )
      assert.equal(response.headers.has('ETag'), false)
      const data = (await response.json()) as typeof original | (typeof original)[]
      const entry = Array.isArray(data) ? data[0]! : data
      assert.equal(entry.description, country === 'CN' ? '中文介绍' : 'English')
      assert.deepEqual({ ...entry, description: original.description }, original)
    }
  }
  const response = await onRequest({ request: request('CN', '', {}, 'HEAD'), env })
  assert.equal(response.status, 200)
  assert.equal(response.headers.get('Content-Language'), 'zh-cn')
  assert.equal(await response.text(), '')
})

test('Invalid methods and paths never fetch assets; failures do not return HTML as JSON', async (t) => {
  const fetchAsset = t.mock.fn(async () => Response.json([]))
  assert.equal((await serveAppLanguage(request('CN', '', {}, 'POST'), fetchAsset)).status, 405)
  const options = await serveAppLanguage(request('CN', '', {}, 'OPTIONS'), fetchAsset)
  assert.equal(options.status, 204)
  assert.equal(options.headers.get('Access-Control-Allow-Methods'), 'GET, HEAD, OPTIONS')
  assert.equal(
    (
      await serveAppLanguage(
        request('CN', '', {}, 'GET', '/raw/apps/demo/launcher.json'),
        fetchAsset,
      )
    ).status,
    404,
  )
  assert.equal(fetchAsset.mock.callCount(), 0)
  assert.equal(
    (
      await serveAppLanguage(
        request('CN'),
        async () => new Response('SPA fallback', { headers: { 'Content-Type': 'text/html' } }),
      )
    ).status,
    404,
  )
  assert.equal(
    (await serveAppLanguage(request('CN'), async () => new Response(null, { status: 404 }))).status,
    404,
  )
  const log = t.mock.method(console, 'error', () => {})
  const failed = await serveAppLanguage(request('CN'), async () => {
    throw new Error('offline')
  })
  assert.equal(failed.status, 503)
  assert.equal(log.mock.callCount(), 1)
})
