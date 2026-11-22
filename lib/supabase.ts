import { createBrowserClient } from '@supabase/ssr'

let browser: ReturnType<typeof createBrowserClient> | undefined

export function supabase() {
  if (!browser) {
    const url = process.env.NEXT_PUBLIC_SUPABASE_URL
    const publicKey =
      process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY ??
      process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY

    if (!url || !publicKey) {
      throw new Error('Supabase public environment variables are not configured.')
    }

    browser = createBrowserClient(url, publicKey)
  }

  return browser
}