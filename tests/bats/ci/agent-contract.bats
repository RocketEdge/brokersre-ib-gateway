#!/usr/bin/env bats
# The agent contract: CLAUDE.md (read by Claude Code) and .github/copilot-instructions.md (read
# by GitHub Copilot) are one text under two names, so both agents follow the same rules, and
# AGENTS.md points to them. CLAUDE.md says "keep them identical"; until the review of #48 no
# check held anyone to it. Needs bash and diff:
#   tests/.bats-core/bin/bats tests/bats/ci

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
}

@test "CLAUDE.md and .github/copilot-instructions.md are the same text" {
  # A failure prints the lines that differ (diff -u, CLAUDE.md first).
  diff -u "${ROOT}/CLAUDE.md" "${ROOT}/.github/copilot-instructions.md"
}

@test "AGENTS.md points to CLAUDE.md as the text identical to the Copilot instructions" {
  grep -q 'Read `CLAUDE.md` (identical to `.github/copilot-instructions.md`)' "${ROOT}/AGENTS.md"
}
