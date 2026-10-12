#!/usr/bin/env node
/**
 * Runs the REAL installBundledSkills() shipped in plugin/godot-bridge.mjs.
 *
 * Two things make this non-trivial, and both are why the previous attempt at
 * this test silently proved nothing:
 *
 *   1. apply() returns at its third line when ctx.subprocess / ctx.timer /
 *      ctx.tools are absent — before the skills code is ever reached. A "thin"
 *      context therefore exits early and installs nothing.
 *   2. The module imports @deepseek-ai/dsh-tools and @deepseek-ai/schemastery,
 *      which plain Node cannot resolve outside the running installation (DSH
 *      injects them). So the plugin is copied into a temp package that carries
 *      minimal stubs for exactly those two specifiers.
 *
 * The function under test is the shipped one — the file is copied verbatim,
 * only its resolvable dependencies are stubbed.
 *
 * Usage: node scripts/run-real-install.test.mjs
 */
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, existsSync, rmSync, readdirSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, resolve, dirname } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const source = join(root, 'plugin', 'godot-bridge.mjs')

const home = mkdtempSync(join(tmpdir(), 'godot-bridge-install-'))
const pkg = join(home, 'pkg')
const priorHome = process.env.DSH_HOME
let failed = 0

try {
  // ── stub package tree ───────────────────────────────────────────────────
  mkdirSync(join(pkg, 'node_modules', '@deepseek-ai', 'dsh-tools'), { recursive: true })
  mkdirSync(join(pkg, 'node_modules', '@deepseek-ai', 'schemastery'), { recursive: true })
  mkdirSync(join(pkg, 'plugin'), { recursive: true })

  writeFileSync(join(pkg, 'node_modules', '@deepseek-ai', 'dsh-tools', 'package.json'),
    JSON.stringify({ name: '@deepseek-ai/dsh-tools', version: '0.0.0-stub', type: 'module', main: 'index.js' }))
  writeFileSync(join(pkg, 'node_modules', '@deepseek-ai', 'dsh-tools', 'index.js'),
    'export function defineTool(x) { return x }\nexport default { defineTool }\n')

  // schemastery is used at module top level: Schema.string().default() and
  // .volatile() (line ~61), then Schema.object() for the Config export.
  writeFileSync(join(pkg, 'node_modules', '@deepseek-ai', 'schemastery', 'package.json'),
    JSON.stringify({ name: '@deepseek-ai/schemastery', version: '0.0.0-stub', type: 'module', main: 'index.js' }))
  writeFileSync(join(pkg, 'node_modules', '@deepseek-ai', 'schemastery', 'index.js'), `
function field() {
  return { default() { return this }, volatile() { return this } }
}
const Schema = { string: field, object: () => ({}) }
export default Schema
`)

  writeFileSync(join(pkg, 'package.json'), JSON.stringify({ name: 'godot-bridge-stub', version: '0.3.0', type: 'module' }))
  // Copy the plugin VERBATIM — this is the shipped file under test.
  writeFileSync(join(pkg, 'plugin', 'godot-bridge.mjs'), readFileSync(source, 'utf8'))

  // The install step reads skills/ relative to the plugin entry.
  mkdirSync(join(pkg, 'skills'), { recursive: true })
  for (const entry of readdirSync(join(root, 'skills'), { withFileTypes: true })) {
    if (!entry.isDirectory()) continue
    if (!existsSync(join(root, 'skills', entry.name, 'SKILL.md'))) continue
    mkdirSync(join(pkg, 'skills', entry.name), { recursive: true })
    writeFileSync(join(pkg, 'skills', entry.name, 'SKILL.md'),
      readFileSync(join(root, 'skills', entry.name, 'SKILL.md'), 'utf8'))
  }

  process.env.DSH_HOME = home

  // ── a ctx complete enough to get past apply()'s early return ────────────
  const logs = []
  const noop = () => {}
  const ctx = {
    subprocess: { spawn: () => ({ done: Promise.resolve({ exitCode: 0 }), collected: null, terminate: noop }) },
    timer: {},
    tools: { register: () => noop },
    effect: (fn) => { try { return fn() } catch (e) { return noop } },
    inject: () => noop,
    // apply() also touches configEditor (legacy settings restore) and
    // systemPrompt; absent members are fine as long as they are not called
    // unguarded — these stubs record the calls instead of throwing.
    configEditor: { edit: () => { throw new Error('not stubbed: configEditor.edit') } },
    systemPrompt: undefined,
    logger: { info: (m) => logs.push(m), warn: (m) => logs.push(m), error: (m) => logs.push(m) },
  }

  const mod = await import(pathToFileURL(join(pkg, 'plugin', 'godot-bridge.mjs')).href)
  if (typeof mod.apply !== 'function') {
    console.error('✖ plugin does not export apply()')
    process.exit(1)
  }

  const target = join(home, 'skills')
  mod.apply(ctx, {})

  if (!existsSync(target)) {
    console.error('✖ apply() created no skills directory at ' + target)
    process.exit(1)
  }

  const expected = readdirSync(join(root, 'skills'), { withFileTypes: true })
    .filter((e) => e.isDirectory() && existsSync(join(root, 'skills', e.name, 'SKILL.md')))
    .map((e) => e.name)

  for (const slug of expected) {
    const to = join(target, slug, 'SKILL.md')
    if (!existsSync(to)) {
      console.error(`✖ ${slug}: not installed`)
      failed++
      continue
    }
    if (readFileSync(join(root, 'skills', slug, 'SKILL.md'), 'utf8') !== readFileSync(to, 'utf8')) {
      console.error(`✖ ${slug}: installed content differs from source`)
      failed++
    } else {
      console.log(`✔ ${slug}: installed byte-identical`)
    }
  }
  if (failed === 0) console.log(`✔ all ${expected.length} skill(s) installed to ${target}`)

  const extra = readdirSync(target, { withFileTypes: true }).filter((e) => e.isDirectory())
    .map((e) => e.name).filter((s) => !expected.includes(s))
  if (extra.length > 0) { console.error('✖ unexpected directories: ' + extra.join(', ')); failed++ }

  // apply() runs on every DSH boot — it must not corrupt on a second pass.
  mod.apply(ctx, {})
  for (const slug of expected) {
    if (readFileSync(join(root, 'skills', slug, 'SKILL.md'), 'utf8') !== readFileSync(join(target, slug, 'SKILL.md'), 'utf8')) {
      console.error(`✖ ${slug}: second apply() corrupted the file`)
      failed++
    }
  }
  if (failed === 0) console.log('✔ second apply() is idempotent')

  // The install must be observable, otherwise a silent no-install is invisible.
  const installLog = logs.find((m) => String(m).includes('installed') && String(m).includes('skill'))
  if (installLog) console.log('✔ plugin logged: ' + installLog)
  else { console.error('✖ plugin never logged the install'); failed++ }
} catch (e) {
  console.error('✖ harness error: ' + String((e && e.stack) || e))
  failed++
} finally {
  if (priorHome === undefined) delete process.env.DSH_HOME
  else process.env.DSH_HOME = priorHome
  rmSync(home, { recursive: true, force: true })
}

if (failed > 0) {
  console.error(`\n${failed} check(s) failed`)
  process.exit(1)
}
console.log('\nreal installBundledSkills() verified')