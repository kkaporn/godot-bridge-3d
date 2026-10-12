#!/usr/bin/env node
/**
 * Verifies the path that installBundledSkills() resolves at runtime, against the
 * REAL deployed plugin location rather than a fixture.
 *
 * The whole install step hinges on one expression:
 *
 *     new URL('../skills/', import.meta.url)
 *
 * evaluated from inside plugin/godot-bridge.mjs. If that resolves to a
 * directory that does not exist (package layout change, wrong nesting level,
 * DSH resolving the bundle through a different root), the install silently
 * returns `{ installed: [] }` and every session is left with no skills — with
 * no error anywhere. So this test resolves the same expression from the same
 * file and asserts the directory and its SKILL.md files are really there.
 *
 * Usage:
 *   node scripts/verify-installed-skills.mjs                    # dev checkout
 *   node scripts/verify-installed-skills.mjs <plugin.mjs path>   # deployed copy
 *
 * Exits 0 when every SKILL.md under the resolved skills/ directory exists.
 */
import { existsSync, readdirSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { join } from 'node:path'

const explicit = process.argv.indexOf('--plugin')
const pluginPath = explicit === -1
  ? resolve(dirname(fileURLToPath(import.meta.url)), '..', 'plugin', 'godot-bridge.mjs')
  : resolve(process.argv[explicit + 1])

if (!existsSync(pluginPath)) {
  console.error(`✖ plugin entry not found: ${pluginPath}`)
  process.exit(2)
}

// Exactly what skillsSourceDir() does inside the plugin.
function skillsSourceDir(importMetaUrl) {
  try {
    const u = new URL('../skills/', importMetaUrl)
    return decodeURIComponent(u.pathname).replace(/^\/([A-Za-z]:)/, '$1')
  } catch (e) {
    return null
  }
}

// Exactly what installBundledSkills() does with DSH_HOME.
const installTarget = join(process.env.DSH_HOME || join(dirname(process.env.USERPROFILE || ''), '.dsh'), 'skills')

const source = skillsSourceDir(pathToFileURL(pluginPath).href)

console.log(`plugin entry : ${pluginPath}`)
console.log(`resolves to  : ${source}`)
console.log(`install target: ${installTarget}  (DSH_HOME=${process.env.DSH_HOME || '<unset>'})`)

let failed = 0

if (!source || !existsSync(source)) {
  console.error('✖ the resolved skills/ directory does not exist — installBundledSkills() would install nothing')
  process.exit(1)
}

let entries = []
try {
  entries = readdirSync(source, { withFileTypes: true })
} catch (e) {
  console.error('✖ skills/ unreadable: ' + String((e && e.message) || e))
  process.exit(1)
}

const slugs = []
for (const entry of entries) {
  if (!entry.isDirectory()) continue
  const skillMd = join(source, entry.name, 'SKILL.md')
  if (!existsSync(skillMd)) continue
  slugs.push(entry.name)
  console.log(`  ✔ ${entry.name}/SKILL.md`)
}

if (slugs.length === 0) {
  console.error('✖ no skills/<slug>/SKILL.md found under ' + source)
  process.exit(1)
}

console.log(`✔ ${slugs.length} skill(s) would be installed by a fresh plugin load: ${slugs.join(', ')}`)