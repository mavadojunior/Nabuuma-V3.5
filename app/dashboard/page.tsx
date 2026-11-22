'use client'

import { useEffect, useState } from 'react'
import { db } from '../../lib/db'

type DashboardData = {
  businessName: string
  products: Array<{
    id: string
    code: string
    name: string
    status: { status: string } | null
  }>
  pass: number
  checks: number
  serves: number
  remakes: number
  ingredients: number
}

export default function Dashboard() {
  const [data, setData] = useState<DashboardData | null>(null)
  const [error, setError] = useState('')

  useEffect(() => {
    let active = true

    async function loadDashboard() {
      try {
        const workspace = await db()
        const businessId = workspace.businessId

        const [products, qc, events, ingredients] = await Promise.all([
          workspace.client
            .from('products')
            .select('id,code,name,status:recipe_versions!products_active_recipe_fk(status)')
            .eq('business_id', businessId)
            .order('created_at', { ascending: false }),
          workspace.client
            .from('qc_checks')
            .select('result')
            .eq('business_id', businessId),
          workspace.client
            .from('service_events')
            .select('id,quantity,remake')
            .eq('business_id', businessId),
          workspace.client
            .from('ingredients')
            .select('id,name')
            .eq('business_id', businessId),
        ])

        const failed = [products, qc, events, ingredients].find((result) => result.error)
        if (failed?.error) throw failed.error

        const qcRows = (qc.data ?? []) as Array<{ result: string | null }>
        const eventRows = (events.data ?? []) as Array<{ quantity: number | null; remake: boolean | null }>

        if (!active) return

        setData({
          businessName: workspace.business?.name ?? 'Workspace',
          products: products.data ?? [],
          pass: qcRows.filter((row) => row.result === 'pass').length,
          checks: qcRows.length,
          serves: eventRows.reduce((total, row) => total + (row.quantity ?? 0), 0),
          remakes: eventRows.filter((row) => row.remake).length,
          ingredients: ingredients.data?.length ?? 0,
        })
      } catch (cause) {
        if (active) {
          setError(cause instanceof Error ? cause.message : 'Dashboard data could not be loaded.')
        }
      }
    }

    void loadDashboard()
    return () => {
      active = false
    }
  }, [])

  if (error) {
    return (
      <div className="card">
        <h2>Connection error</h2>
        <p>{error}</p>
        <p className="muted">Check the Supabase environment settings and database access.</p>
      </div>
    )
  }

  if (!data) return <div className="card">Loading workspace…</div>

  return (
    <>
      <div className="top">
        <div>
          <div className="eyebrow">{data.businessName}</div>
          <h1>Control the standard.</h1>
          <p className="muted">Every number below is read from your Supabase database.</p>
        </div>
      </div>

      <div className="grid">
        {[
          ['Products', data.products.length, 'Database records'],
          ['QC pass rate', data.checks ? `${Math.round((data.pass / data.checks) * 100)}%` : '—', `${data.checks} checks`],
          ['Recorded serves', data.serves, 'Service events'],
          ['Remakes', data.remakes, 'Service records'],
        ].map(([label, value, note]) => (
          <div className="card" key={String(label)}>
            <div className="metricLabel">{label}</div>
            <div className="metric">{value}</div>
            <div className="delta muted">{note}</div>
          </div>
        ))}
      </div>

      <div className="sectionGrid">
        <div className="card">
          <h2>Products</h2>
          <p className="kicker">Current records from PostgreSQL.</p>
          <div className="tableWrap">
            <table className="table">
              <thead><tr><th>Code</th><th>Product</th><th>Recipe status</th></tr></thead>
              <tbody>
                {data.products.slice(0, 8).map((product) => (
                  <tr key={product.id}>
                    <td>{product.code}</td>
                    <td><b>{product.name}</b></td>
                    <td>{product.status?.status ?? 'No recipe'}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </div>

        <div className="card">
          <h2>Data engine</h2>
          <div className="list">
            {[
              'Tenant isolation enforced by business membership and RLS',
              'Published recipes protected by database controls',
              'Inventory recorded through database movements',
              'Audit events tied to the signed-in user',
              `${data.ingredients} ingredients available in this workspace`,
            ].map((item) => (
              <div className="listItem" key={item}><span>{item}</span><span className="pill good">LIVE</span></div>
            ))}
          </div>
        </div>
      </div>
    </>
  )
}