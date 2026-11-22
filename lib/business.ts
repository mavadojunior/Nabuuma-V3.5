'use client'

import { supabase } from './supabase'

export type BusinessMembership = {
  business_id: string
  role: 'owner' | 'manager' | 'trainer' | 'staff'
  businesses: {
    id: string
    name: string
    currency: string
    timezone: string
  } | null
}

type CreateBusinessResult = {
  business_id?: string
  role?: BusinessMembership['role']
  already_member?: boolean
}

export async function getMembership(): Promise<BusinessMembership | null> {
  const client = supabase()
  const { data: { user }, error: authError } = await client.auth.getUser()

  if (authError) throw authError
  if (!user) throw new Error('Not authenticated')

  const { data, error } = await client
    .from('business_members')
    .select('business_id,role,businesses(id,name,currency,timezone)')
    .eq('user_id', user.id)
    .order('created_at', { ascending: true })
    .limit(1)
    .maybeSingle()

  if (error) throw error
  return data as BusinessMembership | null
}

export async function ensureBusiness(
  name = 'Nabuuma Pilot Hospitality'
): Promise<BusinessMembership> {
  const existing = await getMembership()
  if (existing) return existing

  const { data, error } = await supabase().rpc('create_business', {
    business_name: name,
    currency_code: 'AED',
    timezone_name: 'Asia/Dubai',
  })

  if (error) throw error

  const created = data as CreateBusinessResult | null
  if (!created?.business_id) {
    throw new Error('Business onboarding did not return a business identifier.')
  }

  // create_business() is concurrency-safe but its already-member response
  // intentionally omits the embedded business object. Re-read the canonical
  // membership after the RPC so both first and concurrent callers get the
  // same shape.
  const membership = await getMembership()
  if (!membership || membership.business_id !== created.business_id) {
    throw new Error('Business membership could not be loaded after onboarding.')
  }

  return membership
}