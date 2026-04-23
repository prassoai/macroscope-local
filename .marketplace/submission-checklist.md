# Marketplace Submission Checklist

## Phase 1: skills.sh (Day 1)

No submission needed. Auto-registers on first `npx skills add prassoai/macroscope-local`.

- [x] `skills/codereview/SKILL.md` — standalone skill with CLI prerequisite check
- [x] `skills/autoloop/SKILL.md` — standalone skill with CLI prerequisite check
- [x] `scripts/sync-skills-from-back.sh` — programmatic sync from back source of truth
- [x] MIT LICENSE at repo root
- [x] GHA workflow `sync-skills` job added to back release pipeline
- [x] Privacy/terms URLs updated in Codex plugin.json
- [ ] Commit and push `isaac/marketplace-distribution` on macroscope-local
- [ ] Commit and push GHA workflow change on back (staging branch)
- [ ] Merge macroscope-local branch to main
- [ ] Run `npx skills add prassoai/macroscope-local` to trigger skills.sh registration
- [ ] Verify listing at https://skills.sh (search "macroscope")
- [ ] Verify install works: Claude Code, Codex, Cursor, Copilot CLI

## Phase 2: Claude Code Official Marketplace

**Submission portal:** https://claude.com/plugins or Anthropic plugin submission portal

**Required artifacts (already exist in plugin bundle):**
- `.claude-plugin/plugin.json` (v1.5.0) ✓
- Skills: `codereview/SKILL.md`, `autoloop/SKILL.md` ✓
- Branding: `assets/macroscope.svg` ✓

**Submission checklist:**
- [x] Verify plugin.json has valid homepage/repository URLs
- [x] Privacy policy URL: https://app.macroscope.com/privacy
- [x] Terms of service URL: https://app.macroscope.com/terms
- [ ] Submit via portal
- [ ] Respond to Anthropic review feedback
- [ ] Confirm listing goes live

**Expected timeline:** ~1 week after submission

## Phase 3: Cursor Marketplace

**Submission portal:** https://cursor.com/marketplace/publish

**Requirements:**
- Plugin must be open source (MIT license ✓)
- `.cursor-plugin/plugin.json` (v1.5.0) ✓
- Manual review by Cursor team

**Submission checklist:**
- [ ] Submit at cursor.com/marketplace/publish
- [ ] Respond to Cursor team review feedback
- [ ] Confirm listing goes live

**Expected timeline:** ~1-2 weeks after submission

## Phase 4: Codex Official Plugin Directory

**Status:** Self-serve publishing not yet available. Curated by OpenAI only.

**Required artifacts (already exist in plugin bundle):**
- `.codex-plugin/plugin.json` with full interface spec ✓
- Skills with Codex-specific overlays ✓
- Branding assets (SVG logos, brand color #0F766E) ✓
- Privacy/terms URLs ✓

**Submission checklist:**
- [ ] Monitor OpenAI's self-serve plugin publishing announcement
- [ ] Contact OpenAI DevRel for early access (if available)
- [ ] Submit when self-serve opens
- [ ] Respond to review feedback

**Expected timeline:** Unknown — depends on OpenAI's self-serve launch

## Phase 5: GitHub Copilot CLI

**Distribution:** Community marketplace via repo structure. No approval gate.

The skills installed via skills.sh already work with Copilot CLI. No separate submission needed.

- [ ] Verify `npx skills add prassoai/macroscope-local` installs to `.github/skills/` for Copilot

## Optional: Screenshots

- [ ] Capture review experience screenshots for Codex interface spec and README
