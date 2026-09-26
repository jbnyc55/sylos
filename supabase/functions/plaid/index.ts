// Plaid server side, as one edge function with three routes:
//
//   POST /plaid/link-token   → a link_token for opening Plaid Link
//   POST /plaid/exchange     → public_token → access_token, stored in plaid_item
//   POST /plaid/sync         → pull the past week's card purchases into card_purchase
//
// This exists because the web app is static: the Plaid client secret and the
// per-item access tokens must never reach a browser bundle, so every Plaid API
// call happens here. Secrets live in the Supabase dashboard (Edge Functions →
// Secrets), never in this repo:
//
//   PLAID_CLIENT_ID   from the Plaid dashboard
//   PLAID_SECRET      from the Plaid dashboard (production)
//
// Auth: the platform verifies the caller's JWT before this code runs
// (verify_jwt is on). The caller's own token resolves their profile through
// RLS; the service role — auto-injected, never in the client — writes the
// tables the browser is not allowed to write.

import { createClient } from 'npm:@supabase/supabase-js@2'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

/** Call a Plaid endpoint, attaching credentials. Throws on any Plaid error. */
async function plaid(path: string, body: Record<string, unknown>) {
  const res = await fetch(`https://production.plaid.com${path}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      client_id: Deno.env.get('PLAID_CLIENT_ID'),
      secret: Deno.env.get('PLAID_SECRET'),
      ...body,
    }),
  })
  const json = await res.json()
  if (!res.ok) {
    throw new Error(json.error_message ?? `Plaid ${path} failed (${json.error_code ?? res.status})`)
  }
  return json
}

function json(status: number, body: Record<string, unknown>) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  })
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })
  if (req.method !== 'POST') return json(405, { error: 'POST only' })

  const route = new URL(req.url).pathname.split('/').filter(Boolean).pop()

  try {
    // Who is calling? The user's own JWT + RLS resolve the profile, so this
    // function cannot be talked into acting for someone else.
    const userClient = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_ANON_KEY')!,
      { global: { headers: { Authorization: req.headers.get('Authorization') ?? '' } } },
    )
    const { data: profile, error: profileError } = await userClient
      .from('profiles')
      .select('id')
      .single()
    if (profileError || !profile) return json(401, { error: 'Could not resolve your profile.' })

    // Service role: reads access tokens, writes plaid_item and card_purchase.
    const admin = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
    )

    if (route === 'link-token') {
      const data = await plaid('/link/token/create', {
        user: { client_user_id: profile.id },
        client_name: 'projects',
        products: ['transactions'],
        country_codes: ['US'],
        language: 'en',
      })
      return json(200, { link_token: data.link_token })
    }

    if (route === 'exchange') {
      const { public_token, institution_name } = await req.json()
      if (typeof public_token !== 'string' || !public_token) {
        return json(400, { error: 'public_token is required.' })
      }

      const data = await plaid('/item/public_token/exchange', { public_token })

      const { error } = await admin.from('plaid_item').upsert(
        {
          profile_id: profile.id,
          plaid_item_id: data.item_id,
          access_token: data.access_token,
          institution_name: typeof institution_name === 'string' ? institution_name : null,
        },
        { onConflict: 'plaid_item_id' },
      )
      if (error) return json(500, { error: error.message })

      return json(200, { ok: true })
    }

    if (route === 'sync') {
      const { date } = await req.json()
      if (typeof date !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(date)) {
        return json(400, { error: 'date must be YYYY-MM-DD.' })
      }

      // The past week, ending on the caller's local today. A wide window is
      // the fix for bank-to-Plaid lag: a purchase that was still in transit
      // yesterday is caught by today's sync, and the upsert makes re-syncing
      // the overlap free.
      const end = date
      const startDate = new Date(`${date}T00:00:00Z`)
      startDate.setUTCDate(startDate.getUTCDate() - 6)
      const start = startDate.toISOString().slice(0, 10)

      const { data: items, error: itemsError } = await admin
        .from('plaid_item')
        .select('id, access_token, institution_name')
        .eq('profile_id', profile.id)
      if (itemsError) return json(500, { error: itemsError.message })
      if (!items?.length) return json(400, { error: 'No bank connected yet. Connect via Plaid first.' })

      let synced = 0
      let pending = 0
      for (const item of items) {
        // Ask Plaid to go to the bank for fresh data before reading. The
        // refresh is asynchronous and not on every plan, so a failure or a
        // still-running refresh must not block the sync itself.
        await plaid('/transactions/refresh', { access_token: item.access_token }).catch(() => {})

        // A connection made before institution_name was captured shows as
        // "Unnamed bank" in the app; fill it in from Plaid once.
        if (!item.institution_name) {
          try {
            const itemData = await plaid('/item/get', { access_token: item.access_token })
            const institutionId = itemData.item?.institution_id
            if (institutionId) {
              const inst = await plaid('/institutions/get_by_id', {
                institution_id: institutionId,
                country_codes: ['US'],
              })
              await admin
                .from('plaid_item')
                .update({ institution_name: inst.institution.name })
                .eq('id', item.id)
            }
          } catch {
            // Cosmetic only — never fail a sync over a display name.
          }
        }

        // count 500 is far above a realistic week's volume, so no pagination
        // loop is needed.
        const data = await plaid('/transactions/get', {
          access_token: item.access_token,
          start_date: start,
          end_date: end,
          options: { count: 500, include_personal_finance_category: false },
        })

        type PlaidTransaction = {
          transaction_id: string
          account_id: string
          name: string
          merchant_name: string | null
          amount: number
          iso_currency_code: string | null
          date: string
          pending: boolean
        }

        const rows = (data.transactions as PlaidTransaction[]).map((t) => ({
          profile_id: profile.id,
          plaid_item_id: item.id,
          plaid_transaction_id: t.transaction_id,
          account_id: t.account_id,
          name: t.name,
          merchant_name: t.merchant_name,
          amount: t.amount,
          iso_currency_code: t.iso_currency_code,
          date: t.date,
          pending: t.pending,
        }))

        if (rows.length) {
          const { error } = await admin
            .from('card_purchase')
            .upsert(rows, { onConflict: 'plaid_transaction_id' })
          if (error) return json(500, { error: error.message })
        }
        synced += rows.length
        pending += rows.filter((r) => r.pending).length
      }

      return json(200, { synced, pending, start, end })
    }

    return json(404, { error: `Unknown route: ${route}` })
  } catch (err) {
    return json(500, { error: err instanceof Error ? err.message : String(err) })
  }
})
