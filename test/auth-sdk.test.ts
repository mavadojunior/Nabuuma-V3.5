import { beforeEach, describe, expect, it, vi } from 'vitest'
import { createBrowserClient } from '@supabase/ssr'

vi.mock('@supabase/ssr', () => ({
  createBrowserClient: vi.fn(),
}))

const auth = {
  signInWithPassword: vi.fn(),
  signUp: vi.fn(),
}
const client = { auth }

beforeEach(() => {
  vi.resetModules()
  vi.clearAllMocks()
  process.env.NEXT_PUBLIC_SUPABASE_URL = 'https://nabuuma-test.invalid'
  process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY = 'test-publishable-key'
  delete process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY
  vi.mocked(createBrowserClient).mockReturnValue(client as never)
})

describe('browser Supabase Auth SDK boundary', () => {
  it('creates one browser client with the public URL and publishable key', async () => {
    const { supabase } = await import('../lib/supabase')
    const first = supabase()
    const second = supabase()

    expect(first).toBe(second)
    expect(createBrowserClient).toHaveBeenCalledTimes(1)
    expect(createBrowserClient).toHaveBeenCalledWith(
      'https://nabuuma-test.invalid',
      'test-publishable-key',
    )
  })

  it('supports the legacy anon-key environment fallback', async () => {
    delete process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY = 'legacy-anon-test-key'
    const { supabase } = await import('../lib/supabase')

    supabase()

    expect(createBrowserClient).toHaveBeenCalledWith(
      'https://nabuuma-test.invalid',
      'legacy-anon-test-key',
    )
  })

  it('fails closed when public environment variables are absent', async () => {
    delete process.env.NEXT_PUBLIC_SUPABASE_URL
    delete process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY
    delete process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY
    const { supabase } = await import('../lib/supabase')

    expect(() => supabase()).toThrow(
      'Supabase public environment variables are not configured.',
    )
    expect(createBrowserClient).not.toHaveBeenCalled()
  })

  it('forwards password sign-in credentials to the mocked Auth SDK', async () => {
    auth.signInWithPassword.mockResolvedValue({
      data: { user: { id: 'user-1' }, session: { access_token: 'mock-session-token' } },
      error: null,
    })
    const { supabase } = await import('../lib/supabase')
    const sdk = supabase()

    const result = await sdk.auth.signInWithPassword({
      email: 'owner@example.invalid',
      password: 'test-password',
    })

    expect(auth.signInWithPassword).toHaveBeenCalledWith({
      email: 'owner@example.invalid',
      password: 'test-password',
    })
    expect(result.data.session?.access_token).toBe('mock-session-token')
  })

  it('forwards sign-up credentials and returns the mocked confirmation state', async () => {
    auth.signUp.mockResolvedValue({
      data: { user: { id: 'new-user' }, session: null },
      error: null,
    })
    const { supabase } = await import('../lib/supabase')
    const sdk = supabase()

    const result = await sdk.auth.signUp({
      email: 'new-owner@example.invalid',
      password: 'test-password',
    })

    expect(auth.signUp).toHaveBeenCalledWith({
      email: 'new-owner@example.invalid',
      password: 'test-password',
    })
    expect(result.data.session).toBeNull()
  })
})
