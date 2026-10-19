export type AppLanguage = 'en' | 'zh-cn'

type CountryRequest = Request & { cf?: { country?: string | null } }
type AssetFetcher = (request: Request) => Promise<Response>

function supportedLanguage(value: string): AppLanguage | undefined {
  const language = value.trim().toLowerCase().split('-')[0]
  if (language === 'zh') return 'zh-cn'
  if (language === 'en') return 'en'
}

export function appLanguage(request: CountryRequest): AppLanguage {
  const explicit = supportedLanguage(new URL(request.url).searchParams.get('lang') ?? '')
  if (explicit) return explicit
  const preferences = (request.headers.get('Accept-Language') ?? '').split(',').map((part) => {
    const [tag = '', ...parameters] = part.trim().split(';')
    const quality = parameters.find((parameter) => parameter.trim().toLowerCase().startsWith('q='))
    return {
      language: supportedLanguage(tag),
      quality: quality ? Number(quality.split('=')[1]) : 1,
    }
  })
  const preferred = preferences
    .filter(({ language, quality }) => language && quality > 0 && quality <= 1)
    .sort((a, b) => b.quality - a.quality)[0]
  if (preferred?.language) return preferred.language
  // Country comes from Cloudflare, never from client-supplied proxy headers.
  return request.cf?.country === 'CN' ? 'zh-cn' : 'en'
}

export function isAppLanguagePath(pathname: string): boolean {
  return (
    pathname === '/raw/apps-data.json' ||
    pathname === '/raw/catalog-data.json' ||
    /^\/raw\/apps\/[A-Za-z0-9_-]{1,63}\/_metadata\.json$/.test(pathname)
  )
}

export async function serveAppLanguage(
  request: CountryRequest,
  fetchAsset: AssetFetcher,
): Promise<Response> {
  const url = new URL(request.url)
  const language = appLanguage(request)
  const headers = new Headers({
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Language': language,
    // A shared cache must not serve one country's response to another country.
    'Cache-Control': 'private, no-store',
    'CDN-Cache-Control': 'no-store',
    Vary: 'Accept-Language',
    'Access-Control-Allow-Origin': 'https://simulator.esp-claw.com',
  })
  if (request.method === 'OPTIONS') {
    headers.set('Access-Control-Allow-Methods', 'GET, HEAD, OPTIONS')
    headers.set('Access-Control-Allow-Headers', 'Accept-Language')
    return new Response(null, { status: 204, headers })
  }
  if (request.method !== 'GET' && request.method !== 'HEAD') {
    headers.set('Allow', 'GET, HEAD, OPTIONS')
    return new Response('{"error":"Method not allowed"}', { status: 405, headers })
  }
  if (!isAppLanguagePath(url.pathname)) return new Response(null, { status: 404, headers })
  if (language === 'zh-cn') url.pathname = '/raw/i18n/zh-cn/' + url.pathname.slice('/raw/'.length)
  url.search = ''
  try {
    // Fetch a complete static variant without client cache validators or ranges.
    const response = await fetchAsset(new Request(url, { headers: { Accept: 'application/json' } }))
    if (!response.ok)
      return new Response(request.method === 'HEAD' ? null : response.body, {
        status: response.status,
        headers,
      })
    if (!response.headers.get('Content-Type')?.includes('application/json')) {
      return new Response(request.method === 'HEAD' ? null : '{"error":"App catalog not found"}', {
        status: 404,
        headers,
      })
    }
    return new Response(request.method === 'HEAD' ? null : response.body, { headers })
  } catch (error) {
    console.error('[app-language] Asset fetch failed:', url.pathname, error)
    return new Response(request.method === 'HEAD' ? null : '{"error":"App catalog unavailable"}', {
      status: 503,
      headers,
    })
  }
}

export function onRequest(context: {
  request: CountryRequest
  env: { ASSETS: { fetch: AssetFetcher } }
}): Promise<Response> {
  return serveAppLanguage(context.request, (request) => context.env.ASSETS.fetch(request))
}
