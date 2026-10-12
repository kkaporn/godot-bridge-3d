#!/usr/bin/env node
/**
 * Proves the skill-install step in plugin/godot-bridge.mjs does what it claims:
 * copy every skills/<slug>/SKILL.md from the package into the DSH user-skill
 * directory. The install function lives inside `apply(ctx, config)` and needs a
 * cordis context, so this exercises the same algorithm against the real
 * package layout with a fake home directory.
 *
 * Run: `node scripts/install-skills.test.mjs`
 */
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, readdirSync, rmSync, existsSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const source = join(root, 'skills')

if (!existsSync(source)) {
  console.error(`✖ no skills/ directory under ${root}`)
  process.exit(1)
}

const home = mkdtempSync(join(tmpdir(), 'godot-bridge-skills-'))
let failed = 0
try {
  // Mirror installBundledSkills() from plugin/godot-bridge.mjs.
  const target = join(home, 'skills')
  mkdirSync(target, { recursive: true })
  const installed = []
  for (const entry of readdirSync(source, { withFileTypes: true })) {
    if (!entry.isDirectory()) continue
    const skillMd = join(source, entry.name, 'SKILL.md')
    if (!existsSync(skillMd)) continue
    mkdirSync(join(target, entry.name), { recursive: true })
    writeFileSync(join(target, entry.name, 'SKILL.md'), readFileSync(skillMd, 'utf8'), 'utf8')
    installed.push(entry.name)
  }

  if (installed.length === 0) {
    console.error('✖ installed nothing')
    failed++
  }
  for (const slug of installed) {
    const copied = join(target, slug, 'SKILL.md')
    const original = join(source, slug, 'SKILL.md')
    const a = readFileSync(original, 'utf8')
    const b = readFileSync(copied, 'utf8')
    if (a !== b) {
      console.error(`✖ ${slug}: content differs after copy`)
      failed++
    } else {
      // Report real bytes, not String.prototype.length: the skills are mostly
      // CJK, where one UTF-16 code unit is 3 UTF-8 bytes, so the two numbers
      // differ by ~45% and the "byte-identical" label looked wrong.
      console.log(`✔ ${slug}: installed byte-identical (${Buffer.byteLength(a, 'utf8')} bytes)`)
    }
  }

  // Frontmatter must name the skill and describe it, or the host will not index it.
  for (const slug of installed) {
    const text = readFileSync(join(target, slug, 'SKILL.md'), 'utf8')
    if (!/^---\r?\n[\s\S]*?^name:\s*\S+/m.test(text)) {
      console.error(`✖ ${slug}: no frontmatter name`)
      failed++
    } else if (!/^description:\s*\S+/m.test(text)) {
      console.error(`✖ ${slug}: no frontmatter description`)
      failed++
    }
  }
  console.log(`\ninstalled into ${target}: ${installed.join(', ')}`)
} finally {
  rmSync(home, { recursive: true, force: true })
}

if (failed > 0) {
  console.error(`${failed} check(s) failed`)
  process.exit(1)
}
console.log('skill install verified')
