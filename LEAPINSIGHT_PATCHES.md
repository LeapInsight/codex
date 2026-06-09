# LeapInsight Codex Fork Patches

This fork tracks `openai/codex` and carries a small local patch for teams that
ship many skills or plugins.

## Patch: configurable skill metadata budget

Upstream Codex reserves roughly 2% of the model context window for the initial
model-visible skill metadata list. When many skills are enabled, descriptions
can be shortened and Codex prints this warning:

```text
Skill descriptions were shortened to fit the 2% skills context budget.
```

This fork keeps the upstream default when no config is set, and adds two
optional config keys under `[skills]`:

```toml
[skills]
# Percent of the model context window reserved for the initial skill list.
# Defaults to 2 when unset.
metadata_context_window_percent = 10

# Optional exact token budget. When set to a positive value, this takes
# precedence over metadata_context_window_percent.
# metadata_token_budget = 27000
```

Behavior:

- unset config remains upstream-compatible at 2%;
- `metadata_context_window_percent = 10` changes the warning to say 10%;
- `metadata_token_budget = 27000` uses an absolute token budget instead of a
  context-window percentage;
- if the model context window is unavailable, Codex still falls back to the
  existing 8,000 character budget.

Touched areas:

- config parsing and generated schema: `codex-rs/config`, `codex-rs/core/config.schema.json`;
- effective session config: `codex-rs/core/src/config`, `codex-rs/core/src/session`;
- skill metadata rendering and warnings: `codex-rs/core-skills/src/render.rs`.

Related links:

- Fork PR: <https://github.com/LeapInsight/codex/pull/2>
- Upstream feature request: <https://github.com/openai/codex/issues/19679>

## Build from this fork

If a GitHub Release is available, prefer installing the fork build as
`codex-leap` so it can live beside an official `codex` installation:

```bash
curl -fsSL https://github.com/LeapInsight/codex/releases/latest/download/install-leap.sh | sh
codex-leap --version
```

Source builds remain useful for development and for validating upstream syncs:

```bash
git clone https://github.com/LeapInsight/codex.git
cd codex/codex-rs

curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
export PATH="$HOME/.cargo/bin:$PATH"
rustup toolchain install 1.95.0
rustup component add rustfmt clippy --toolchain 1.95.0

CARGO_NET_GIT_FETCH_WITH_CLI=true cargo build -p codex-cli --bin codex
./target/debug/codex --version
```

For daily local use, build release and expose it under a separate command name
so it does not overwrite an existing official Codex install:

```bash
CARGO_NET_GIT_FETCH_WITH_CLI=true cargo build --release -p codex-cli --bin codex
mkdir -p "$HOME/.local/bin"
ln -sf "$PWD/target/release/codex" "$HOME/.local/bin/codex-leap"
codex-leap --version
```

Then add the config to `~/.codex/config.toml`:

```toml
[skills]
metadata_context_window_percent = 10
```

You can also test the setting for a single run:

```bash
codex-leap -c skills.metadata_context_window_percent=10 "summarize this repository"
```

## Release packaging

Fork releases intentionally use a lightweight workflow instead of upstream's
full OpenAI release pipeline. The fork release workflow avoids OpenAI npm,
Homebrew, WinGet, docs deploy, codesigning, notarization, and custom runner
assumptions.

Create or update a fork release by pushing a `leap-v*` tag or running the
`leap-release` workflow manually:

```bash
git tag leap-v0.0.0-skill-budget.N
git push origin leap-v0.0.0-skill-budget.N
```

The workflow currently uploads:

- `codex-package-aarch64-apple-darwin.tar.gz`
- `codex-package_SHA256SUMS`
- `install-leap.sh`

The installer downloads the matching package for the local platform, verifies
the archive against `codex-package_SHA256SUMS`, installs the package under
`~/.codex/packages/leap-standalone`, and exposes `~/.local/bin/codex-leap`.

Initial binary releases target macOS Apple Silicon. Build from source on other
platforms until the Linux musl/bwrap release toolchain is enabled in this fork.

macOS release packages are currently unsigned and not notarized. If Gatekeeper
blocks a downloaded package, the release process should either add Apple
signing/notarization or document the quarantine removal needed for that release.

## Upstream sync

Keep the fork patch small and rebase it onto upstream rather than carrying a
large divergence:

```bash
git fetch upstream
git checkout feat/skill-metadata-budget-config
git rebase upstream/main
cd codex-rs
CARGO_NET_GIT_FETCH_WITH_CLI=true cargo test -p codex-core-skills default_budget --lib
CARGO_NET_GIT_FETCH_WITH_CLI=true cargo test -p codex-core-skills budgeted_rendering_ --lib
CARGO_NET_GIT_FETCH_WITH_CLI=true cargo test -p codex-core config_schema_matches_fixture --lib
CARGO_NET_GIT_FETCH_WITH_CLI=true cargo test -p codex-core parses_bundled_skills_config --lib
```

The expected conflict hotspot is `codex-rs/core-skills/src/render.rs`, because
that file owns the skill metadata budget model and warning text. The config and
schema files should generally be mechanical to re-apply.

Remove this patch when upstream provides an equivalent configurable skill
metadata budget and the fork no longer needs different behavior.

## Verification

Run the focused tests for this patch:

```bash
cd codex-rs
export PATH="$HOME/.cargo/bin:$PATH"
CARGO_NET_GIT_FETCH_WITH_CLI=true cargo test -p codex-core-skills default_budget --lib
CARGO_NET_GIT_FETCH_WITH_CLI=true cargo test -p codex-core-skills budgeted_rendering_ --lib
CARGO_NET_GIT_FETCH_WITH_CLI=true cargo test -p codex-core config_schema_matches_fixture --lib
CARGO_NET_GIT_FETCH_WITH_CLI=true cargo test -p codex-core parses_bundled_skills_config --lib
```
