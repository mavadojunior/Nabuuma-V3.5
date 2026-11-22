'use client'

import { supabase } from './supabase'
import { ensureBusiness } from './business'

export async function db() {
  const membership = await ensureBusiness()

  return {
    client: supabase(),
    businessId: membership.business_id,
    role: membership.role,
    business: membership.businesses,
  }
}

export async function audit(
  action: string,
  entityType?: string,
  entityId?: string,
  metadata?: Record<string, unknown>,
) {
  const workspace = await db()
  const { data: { user }, error: userError } = await workspace.client.auth.getUser()

  if (userError) throw userError
  if (!user) throw new Error('Not authenticated')

  const { error } = await workspace.client.from('audit_logs').insert({
    business_id: workspace.businessId,
    user_id: user.id,
    action,
    entity_type: entityType,
    entity_id: entityId,
    metadata,
  })

  if (error) throw error
}