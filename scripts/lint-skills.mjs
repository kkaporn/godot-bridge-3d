#!/usr/bin/env node
/**
 * Capability lint for the bundled skills.
 *
 * Why this exists — the skills/ directory ships Markdown that the model loads
 * as instructions. A single poisoned line in any SKILL.md would be executed
 * verbatim by the agent on the next session. These rules make the dangerous
 * shapes impossible to merge by accident:
 *
 *   1. url-allowlist          outbound links to hosts outside the allowlist
 *   2. install-command        package-manager installs, curl|sh, npx <third-party>
 *   3. credential-pattern     secrets, token files, env keys
 *   4. base64-blob            encoded payloads (possibly wrapped over 2 lines)
 *   5. invisible-unicode      zero-width / bidi / tag-block smuggling
 *   6. prompt-injection-phrase  "ignore previous instructions" style overrides
 *   7. destructive-command    rm -rf on ~, /, $HOME
 *
 * A skill may exempt a rule with `<!-- lint-allow rule-id: reason -->`; every
 * exemption is printed loudly so a reviewer sees it.
 *
 * Run: `npm run check:skills` (CI should run it — the whole point is CI).
 */
import { readFileSync, readdirSync, existsSync } from 'node:fs'
import { dirname, join, relative, resolve, sep } from 'node:path'
import { fileURLToPath } from 'node:url'

const rootArgument = process.argv.indexOf('--root')
const root = rootArgument === -1
  ? resolve(dirname(fileURLToPath(import.meta.url)), '..')
  : resolve(process.argv[rootArgument + 1] ?? '')

// Hosts a game-dev skill may legitimately cite. Loopback (127.0.0.1 /
// localhost) is always allowed: it can only reach software already running on
// the user's own machine, which is exactly what the in-game interaction server
// on :9090 is.
const ALLOWED_HOSTS = [
  'docs.godotengine.org',
  'godotengine.org',
  'github.com/godotengine',
  'raw.githubusercontent.com',
  'store.steampowered.com',
  'partner.steamgames.com',
  'steamcommunity.com',
]

const URL_TAIL = '[^\\s)"\'<>\\]`]+'
const URL_RE = new RegExp(`\\bhttps?://${URL_TAIL}`, 'gi')
const NON_HTTP_SCHEME_RE = new RegExp(
  `\\b(?:ftp|ftps|sftp|file|gopher|smb|ssh|git|telnet|ldap|ldaps)://${URL_TAIL}`,
  'gi',
)
const DATA_URI_RE = /\bdata:[a-z]+\/[a-z0-9.+-]+(?:;[a-z0-9=-]+)*,/gi
const PROTOCOL_RELATIVE_RE = new RegExp(`(?<![\\w:/])//([a-z0-9-]+(?:\\.[a-z0-9-]+)+)(/${URL_TAIL.slice(0, -1)}*)?`, 'gi')
const BARE_DOMAIN_RE = new RegExp(
  `(?<![\\w./@:-])((?:[a-z0-9-]+\\.)*[a-z0-9-]+\\.(?:com|net|io|dev|org))(/[${URL_TAIL.slice(1, -2)}]*)`,
  'gi',
)

const INSTALL_PATTERNS = [
  { re: /\bnpm\s+(i|install)\b/i, label: 'npm install' },
  { re: /\bpnpm\s+(add|i|install)\b/i, label: 'pnpm install' },
  { re: /\byarn\s+(add|global\s+add)\b/i, label: 'yarn add' },
  { re: /\bpip3?\s+install\b/i, label: 'pip install' },
  { re: /\b(cargo|gem|apt(?:-get)?|choco|winget|scoop|bun|deno)\s+(install|add)\b/i, label: 'package-manager install/add' },
  { re: /\bbunx\s+[@a-z0-9][@a-z0-9._\/-]*/i, label: 'bunx <package>' },
  { re: /\bcurl\b[\s\S]{0,200}?\|\s*(ba|z|da)?sh\b/i, label: 'curl | sh' },
  { re: /\bwget\s/i, label: 'wget' },
]

// `npx <pkg>` only fires when a forcing flag is present or the token actually
// looks like a package name — bare words after "npx" in prose are not commands.
const NPX_RE = /\bnpx\s+(-y\s+|--yes\s+)?([@a-z0-9][@a-z0-9._\/-]*)/gi
const NPX_PACKAGE_LIKE_RE = /[@/.\d-]/

const CREDENTIAL_PATTERNS = [
  { re: /~\/\.ssh/, label: '~/.ssh' },
  { re: /~\/\.(aws|npmrc|config\/gh|docker|kube)\b/, label: '~/.aws|.npmrc|.config/gh|.docker|.kube' },
  { re: /(?<![\w.-])\.env\b/, label: '.env' },
  { re: /\bAPI_KEY/, label: 'API_KEY' },
  { re: /\b[A-Z0-9_]*(SECRET|PASSWORD|PASSWD|TOKEN)[A-Z0-9_]*\s*[:=]/, label: 'SECRET|PASSWORD|PASSWD|TOKEN assignment' },
  { re: /\bBearer\s+\S/, label: 'Bearer <credential>' },
]

const DESTRUCTIVE_PATTERNS = [
  { re: /\brm\s+-[a-zA-Z]*[rR][a-zA-Z]*\s+(~|\/|\$HOME)/, label: 'rm -rf on ~, /, or $HOME' },
]

const BASE64_MIN_LENGTH = 160
const BASE64_STD_RE = /[A-Za-z0-9+/=]{160,}/g
const BASE64_URLSAFE_RE = /[A-Za-z0-9_-]{160,}/g
const BASE64_LINE_RE = /^[A-Za-z0-9+/=_-]+$/
const HAS_LETTER_AND_DIGIT_RE = /(?=.*[A-Za-z])(?=.*[0-9])/

const INVISIBLE_RE = /[\u200B\u200C\u200D\u2060\uFEFF\u00AD\u202A-\u202E\u2066-\u2069\u2061-\u2064\u180E\u3164\uFFA0\u{E0000}-\u{E007F}]/u
const STRAY_VS16_RE = /(?<![\p{Extended_Pictographic}\p{S}\d#*\u20E3\uFE0F])\uFE0F/u

const INJECTION_PATTERNS = [
  { re: /\bignore\W+(all\W+)?(the\W+)?(previous|prior|above|earlier)\b(?!-)/i, label: '"ignore previous/prior/above/earlier"' },
  { re: /\bignore\s+the\s+user\b/i, label: '"ignore the user"' },
  { re: /\bignore your system prompt\b/i, label: '"ignore your system prompt"' },
  { re: /\bdisregard\b.{0,40}\b(instructions|prompt|rules)\b/i, label: '"disregard instructions/prompt/rules"' },
  { re: /\bnew instructions\s*:/i, label: '"new instructions:"' },
]

const ALLOW_MARKER_RE = /<!--\s*lint-allow\s+([a-z-]+)\s*:\s*([^>]*?)-->/g

function urlAllowed(raw) {
  let url
  try {
    url = new URL(raw)
  } catch {
    return false // unparseable URL-looking string fails closed
  }
  const host = url.hostname.toLowerCase()
  if (host === 'localhost' || host === '127.0.0.1' || host === '::1') return true
  return ALLOWED_HOSTS.includes(host)
}

function stripTrailingPunctuation(raw) {
  return raw.replace(/[.,;:!?]+$/, '')
}

function detectEncodedBlob(text) {
  for (const re of [BASE64_STD_RE, BASE64_URLSAFE_RE]) {
    for (const match of text.matchAll(re)) {
      if (match[0].length >= BASE64_MIN_LENGTH && HAS_LETTER_AND_DIGIT_RE.test(match[0])) return true
    }
  }
  const lines = text.split(/\r?\n/).map((l) => l.trim())
  for (let i = 0; i + 1 < lines.length; i++) {
    const a = lines[i]
    const b = lines[i + 1]
    if (a && b && BASE64_LINE_RE.test(a) && BASE64_LINE_RE.test(b)) {
      if ((a + b).length >= BASE64_MIN_LENGTH && HAS_LETTER_AND_DIGIT_RE.test(a + b)) return true
    }
  }
  return false
}

function lintText(text, location, exemptions) {
  const findings = []
  const report = (rule, message) => {
    if (exemptions.has(rule)) {
      exemptions.get(rule).push(location)
      return
    }
    findings.push({ rule, location, message })
  }

  let remaining = text
  for (const match of text.matchAll(URL_RE)) {
    const raw = stripTrailingPunctuation(match[0])
    if (!urlAllowed(raw)) report('url-allowlist', `URL host not in the skill allowlist: ${raw}`)
  }
  remaining = remaining.replace(URL_RE, (m) => ' '.repeat(m.length))
  for (const match of remaining.matchAll(NON_HTTP_SCHEME_RE)) {
    report('url-allowlist', `non-http URL scheme is never allowed: ${stripTrailingPunctuation(match[0])}`)
  }
  remaining = remaining.replace(NON_HTTP_SCHEME_RE, (m) => ' '.repeat(m.length))
  for (const match of remaining.matchAll(DATA_URI_RE)) {
    report('url-allowlist', `data: URI detected: ${match[0].slice(0, 40)}`)
  }
  for (const match of remaining.matchAll(PROTOCOL_RELATIVE_RE)) {
    const raw = stripTrailingPunctuation(`https:${match[0]}`)
    if (!urlAllowed(raw)) report('url-allowlist', `scheme-relative URL host not in allowlist: ${raw}`)
  }
  remaining = remaining.replace(PROTOCOL_RELATIVE_RE, (m) => ' '.repeat(m.length))
  for (const match of remaining.matchAll(BARE_DOMAIN_RE)) {
    const raw = stripTrailingPunctuation(`https://${match[0]}`)
    if (!urlAllowed(raw)) report('url-allowlist', `bare domain URL host not in allowlist: ${raw}`)
  }

  for (const { re, label } of INSTALL_PATTERNS) {
    if (re.test(text)) report('install-command', `install command detected (${label})`)
  }
  for (const match of text.matchAll(NPX_RE)) {
    const forced = match[1] !== undefined
    const pkg = match[2].toLowerCase()
    if (!forced && !NPX_PACKAGE_LIKE_RE.test(pkg)) continue
    report('install-command', `npx targeting a third-party package: ${match[2]}`)
  }
  for (const { re, label } of CREDENTIAL_PATTERNS) {
    if (re.test(text)) report('credential-pattern', `credential/env pattern detected (${label})`)
  }
  for (const { re, label } of DESTRUCTIVE_PATTERNS) {
    if (re.test(text)) report('destructive-command', `destructive command detected (${label})`)
  }
  if (detectEncodedBlob(text)) {
    report('base64-blob', `encoded blob detected (>=${BASE64_MIN_LENGTH} consecutive base64 chars, possibly wrapped)`)
  }
  const invisible = text.match(INVISIBLE_RE) ?? text.match(STRAY_VS16_RE)
  if (invisible) {
    const code = invisible[0].codePointAt(0).toString(16).toUpperCase().padStart(4, '0')
    report('invisible-unicode', `invisible/bidi unicode character detected (U+${code})`)
  }
  for (const { re, label } of INJECTION_PATTERNS) {
    if (re.test(text)) report('prompt-injection-phrase', `prompt-injection phrase detected (${label})`)
  }
  return findings
}

function collectMarkdown(dir, out = []) {
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const full = join(dir, entry.name)
    if (entry.isDirectory()) collectMarkdown(full, out)
    else if (entry.name.endsWith('.md')) out.push(full)
  }
  return out
}

const skillsDir = join(root, 'skills')
if (!existsSync(skillsDir)) {
  console.log('no skills/ directory — nothing to lint')
  process.exit(0)
}

const exemptions = new Map()
const files = collectMarkdown(skillsDir)
const problems = []

for (const abs of files) {
  const rel = relative(root, abs).split(sep).join('/')
  const text = readFileSync(abs, 'utf8').replace(/^\uFEFF/, '')
  const local = new Map()
  for (const match of text.matchAll(ALLOW_MARKER_RE)) {
    const rule = match[1]
    const reason = (match[2] || '(no reason given)').trim()
    if (!local.has(rule)) local.set(rule, [])
    local.get(rule).push(reason)
  }
  for (const [rule, reasons] of local) {
    if (!exemptions.has(rule)) exemptions.set(rule, [])
    exemptions.get(rule).push({ file: rel, reasons })
  }
  for (const finding of lintText(text, rel, local)) {
    problems.push(finding)
  }
}

if (exemptions.size > 0) {
  console.log('⚠ lint exemptions in use:')
  for (const [rule, uses] of exemptions) {
    for (const use of uses) {
      for (const reason of use.reasons) console.log(`   ${rule} — ${use.file}: ${reason}`)
    }
  }
}

if (problems.length > 0) {
  console.error(`✖ capability lint: ${problems.length} finding(s) in skills/`)
  for (const p of problems) console.error(`   [${p.rule}] ${p.location}: ${p.message}`)
  process.exit(1)
}

console.log(`✔ capability lint: ${files.length} skill file(s) clean`)
