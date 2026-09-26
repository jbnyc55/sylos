#!/usr/bin/env node
//
// Read the production database as the `claude` role, and append to agent_edits.
//
// The role's permissions are the real boundary, enforced by Postgres: it holds
// SELECT on public and INSERT on public.agent_edits, and nothing else. The
// guards in this file produce clearer errors than the database would — they are
// not the security model, and removing them would not widen what this
// connection can do.
//
// Requires CLAUDE_DB_URL. See notes/06-agent-db-access.md.

import pg from 'pg'

const USAGE = `
Usage: node scripts/agent-db.mjs <command> [options]

  check                       Verify the connection and report what the role can do
  tables                      List readable tables with approximate row counts
  query <sql>                 Run a read-only SELECT
  log --action A --summary S  Append a row to agent_edits
       [--target T] [--details JSON] [--agent NAME]

Options:
  --json                      Machine-readable output

Environment:
  CLAUDE_DB_URL               Postgres connection string for the claude role
`.trim()

function fail(message, code = 1) {
  console.error(`error: ${message}`)
  process.exit(code)
}

function parseFlags(argv) {
  const flags = {}
  const positional = []
  for (let i = 0; i < argv.length; i++) {
    if (argv[i].startsWith('--')) {
      const key = argv[i].slice(2)
      if (key === 'json') flags.json = true
      else flags[key] = argv[++i]
    } else {
      positional.push(argv[i])
    }
  }
  return { flags, positional }
}

function connect() {
  const connectionString = process.env.CLAUDE_DB_URL
  if (!connectionString) {
    fail(
      'CLAUDE_DB_URL is not set.\n' +
        '       Add it to this environment as a Postgres connection string for the\n' +
        '       claude role. See notes/06-agent-db-access.md for the exact format.',
    )
  }
  // Supabase terminates TLS with a certificate chain this client has no root
  // for, so verification is off while the connection stays encrypted. An
  // explicit sslmode=disable in the URL is honoured, which is what makes this
  // usable against a local Postgres that has no TLS configured.
  const ssl = /[?&]sslmode=disable\b/.test(connectionString)
    ? false
    : { rejectUnauthorized: false }
  return new pg.Client({ connectionString, ssl })
}

// A SELECT-only guard. The read-only transaction in cmdQuery is what actually
// stops a write; this exists so a mistake reads as "not a read-only statement"
// rather than as a permission error from Postgres.
function assertReadOnly(sql) {
  const stripped = sql
    .replace(/--[^\n]*/g, ' ')
    .replace(/\/\*[\s\S]*?\*\//g, ' ')
    .trim()
  if (!/^(select|with|explain|show|table)\b/i.test(stripped)) {
    fail('only read-only statements are allowed here; use `log` to write')
  }
}

async function cmdCheck(client, flags) {
  const { rows: who } = await client.query('select current_user, current_database()')

  const { rows: privileges } = await client.query(`
    select table_name, string_agg(privilege_type, ', ' order by privilege_type) as privileges
    from information_schema.role_table_grants
    where grantee = current_user and table_schema = 'public'
    group by table_name order by table_name
  `)

  // Prove the write boundary rather than asserting it: attempt a forbidden
  // write and confirm the database refuses it.
  let writeBlocked
  try {
    await client.query('begin')
    await client.query(
      "insert into public.notes (profile_id, body) values (gen_random_uuid(), 'probe')",
    )
    writeBlocked = 'NO — this role can write to notes, which it should not be able to'
  } catch (error) {
    writeBlocked = `yes (${error.message.split('\n')[0]})`
  } finally {
    await client.query('rollback').catch(() => {})
  }

  if (flags.json) {
    console.log(JSON.stringify({ user: who[0], privileges, writeBlocked }, null, 2))
    return
  }

  console.log(`connected as ${who[0].current_user} to ${who[0].current_database}\n`)
  console.log('table privileges in public:')
  for (const row of privileges) console.log(`  ${row.table_name.padEnd(14)} ${row.privileges}`)
  console.log(`\nwrite to a non-agent_edits table blocked: ${writeBlocked}`)
}

async function cmdTables(client, flags) {
  const { rows } = await client.query(`
    select relname as table, n_live_tup as approx_rows
    from pg_stat_user_tables where schemaname = 'public' order by relname
  `)
  if (flags.json) return void console.log(JSON.stringify(rows, null, 2))
  if (!rows.length) return void console.log('no readable tables')
  for (const row of rows) console.log(`  ${row.table.padEnd(14)} ~${row.approx_rows} rows`)
}

async function cmdQuery(client, sql, flags) {
  assertReadOnly(sql)
  // Belt and braces: even if the guard above is wrong, this transaction cannot
  // write.
  await client.query('begin read only')
  try {
    const result = await client.query(sql)
    if (flags.json) console.log(JSON.stringify(result.rows, null, 2))
    else if (!result.rows.length) console.log('(0 rows)')
    else console.table(result.rows)
  } finally {
    await client.query('rollback').catch(() => {})
  }
}

async function cmdLog(client, flags) {
  if (!flags.action || !flags.summary) fail('log requires --action and --summary')

  let details = null
  if (flags.details) {
    try {
      details = JSON.parse(flags.details)
    } catch {
      fail('--details must be valid JSON')
    }
  }

  const { rows } = await client.query(
    `insert into public.agent_edits (agent, action, target, summary, details)
     values ($1, $2, $3, $4, $5)
     returning id, created_at`,
    [flags.agent ?? 'claude', flags.action, flags.target ?? null, flags.summary, details],
  )

  if (flags.json) console.log(JSON.stringify(rows[0], null, 2))
  else console.log(`logged ${rows[0].id} at ${rows[0].created_at.toISOString()}`)
}

const { flags, positional } = parseFlags(process.argv.slice(2))
const [command, ...rest] = positional

if (!command || command === 'help' || flags.help) {
  console.log(USAGE)
  process.exit(command ? 0 : 1)
}

const client = connect()
try {
  await client.connect()
} catch (error) {
  fail(
    `could not connect: ${error.message}\n` +
      '       Check CLAUDE_DB_URL, and that this environment is allowed to reach\n' +
      '       the database host on its port. See notes/06-agent-db-access.md.',
  )
}

try {
  switch (command) {
    case 'check':
      await cmdCheck(client, flags)
      break
    case 'tables':
      await cmdTables(client, flags)
      break
    case 'query':
      if (!rest.length) fail('query requires a SQL string')
      await cmdQuery(client, rest.join(' '), flags)
      break
    case 'log':
      await cmdLog(client, flags)
      break
    default:
      fail(`unknown command: ${command}\n\n${USAGE}`)
  }
} catch (error) {
  fail(error.message)
} finally {
  await client.end().catch(() => {})
}
