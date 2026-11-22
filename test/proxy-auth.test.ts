import { beforeEach, describe, expect, it, vi } from 'vitest'
import { NextRequest } from 'next/server'
import { createServerClient } from '@supabase/ssr'
import { proxy } from '../proxy'

vi.mock('@supabase/ssr', () => ({
  createServerClient: vi.fn(),
}))

const getClaims = vi.fn()

function request(path = '/dashboard') {
  return new NextRequest(`http://localhost${path}`)
}

beforeEach(() => {
  vi.clearAllMocks()
  process.env.NEXT_PUBLIC_SUPABASE_URL = 'https://nabuuma-test.invalid'
  process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY = 'test-publishable-key'
  vi.mocked(createServerClient).mockReturnValue({
    auth: { getClaims },
  } as never)
  getClaims.mockResolvedValue({ data: { claims: null }, error: null })
})

describe('server-side Supabase Auth session boundary', () => {
  it('returns 503 when public Supabase configuration is missing', async () => {
    delete process.env.NEXT_PUBLIC_SUPABASE_URL

    const response = await proxy(request())

    expect(response.status).toBe(503)
    expect(createServerClient).not.toHaveBeenCalled()
  })

  it('redirects unauthenticated users from protected routes to login', async () => {
    const response = await proxy(request('/dashboard'))

    expect(response.status).toBe(307)
    expect(response.headers.get('location')).toBe('http://localhost/login')
    expect(getClaims).toHaveBeenCalledTimes(1)
  })

  it('allows a request with a verified subject claim and applies security headers', async () => {
    getClaims.mockResolvedValue({
      data: { claims: { sub: 'user-123', role: 'authenticated' } },
      error: null,
    })

    const response = await proxy(request('/dashboard'))

    expect(response.status).toBe(200)
    expect(response.headers.get('x-middleware-next')).toBe('1')
    expect(response.headers.get('x-frame-options')).toBe('DENY')
    expect(response.headers.get('x-content-type-options')).toBe('nosniff')
  })

  it('redirects an authenticated user away from the login page', async () => {
    getClaims.mockResolvedValue({
      data: { claims: { sub: 'user-123', role: 'authenticated' } },
      error: null,
    })

    const response = await proxy(request('/login'))

    expect(response.status).toBe(307)
    expect(response.headers.get('location')).toBe('http://localhost/dashboard')
  })

  it('treats Auth SDK errors as unauthenticated', async () => {
    getClaims.mockResolvedValue({
      data: { claims: { sub: 'user-123' } },
      error: new Error('invalid token'),
    })

    const response = await proxy(request('/dashboard'))

    expect(response.status).toBe(307)
    expect(response.headers.get('location')).toBe('http://localhost/login')
  })
})
