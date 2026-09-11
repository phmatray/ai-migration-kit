---
title: Home
nav_order: 1
---

{%- assign plugin_hosts = site.data.hosts | where: "tier", "plugin" -%}
{%- assign rule_hosts = site.data.hosts | where: "tier", "rules" -%}

# AI Migration Kit

<section class="kit-hero">
<p class="kit-hero-lead">Agent skills for two loops. One takes a legacy .NET application to verified production, with RoselineMCP doing every C# analysis and edit. The other takes a GitHub issue to a merged pull request, hands-off. Every step of both runs behind a gate that refuses by name.</p>
<div class="kit-loop">
<p class="kit-loop-name">Migrate a legacy .NET application</p>
<ol class="kit-stages"><li>assess</li><li>baseline</li><li>retarget</li><li>remediate</li><li>modernize</li><li>verify</li><li>deliver</li></ol>
</div>
<div class="kit-loop">
<p class="kit-loop-name">Take an issue to a merged pull request</p>
<ol class="kit-stages"><li>create-issue</li><li>implement-issue</li><li>merge-pr</li></ol>
</div>
</section>

[Install on your agent](#install){: .btn .btn-primary } [Read the method](methodology.md){: .btn }

Written for Claude Code; installs as a plugin on {{ plugin_hosts.size }} hosts, and loads through a
rule file on {{ rule_hosts.size }} more families of editors and agents.

## Proven on four dead platforms

Four apps from 2013–2016, built for platforms nothing runs any more, were audited, migrated to
Blazor WebAssembly and verified live — characterization tests first, legacy data and art byte for
byte, measured WCAG AA, offline proven with the network cut.

| App, live | From | Pipeline, measured |
|---|---|---|
| [Chords](https://phmatray.github.io/chords/) | Windows Phone | **18 min** |
| [Les Fleurs du Mal](https://phmatray.github.io/fleurs-du-mal-winrt/) | WinRT 8.1 | **~30 min** |
| [Pokédex G](https://phmatray.github.io/pokedexg/) | UWP, SQLite 49 MB | **~1 h** |
| [Sokoban](https://phmatray.github.io/winrt-sokoban/) | WinRT 8.1 | first wave, not timed |

The minutes come from the gate commits, not a stopwatch. The audit, the reports and what each wave
taught the kit: [the case study](case-studies/winrt-portfolio/portfolio.md).

## What the gates refuse

| Without the kit | What stops it |
|---|---|
| Upgrading means bumping the target framework and hoping. | Seven phases, each ending at a build, test and diagnostics gate. A red gate stops the pipeline. |
| The agent reads whole C# files instead of asking Roslyn. | The roseline gate denies a `Read` of a `.cs` file and names the RoselineMCP tool that replaces it. |
| Four agents share one checkout, and a commit lands in another agent's pull request. | Guarded git writes check the branch before and after, and the write-gate denies the raw command. |
| The fix ships before the cause is known. | `debug-issue` finds the root cause before any patch. |
| The backlog only ever fills. | One filing bar for every inlet, and `triage-backlog` to re-decide what is already open. |

## Install on your agent {#install}

<div class="kit-picker">
{%- for host in plugin_hosts %}
<input type="radio" name="kit-host" id="kit-host-{{ host.id }}"{% if forloop.first %} checked{% endif %}><label for="kit-host-{{ host.id }}">{{ host.name }}</label>
{%- endfor %}
<input type="radio" name="kit-host" id="kit-host-rules"><label for="kit-host-rules">Other hosts</label>
{%- for host in plugin_hosts %}
<div class="kit-picker-panel">
<div class="language-bash highlighter-rouge"><div class="highlight"><pre class="highlight"><code>{{ host.install | join: "
" | xml_escape }}</code></pre></div></div>
{{ host.then | markdownify }}
</div>
{%- endfor %}
<div class="kit-picker-panel">
<div class="language-bash highlighter-rouge"><div class="highlight"><pre class="highlight"><code>git clone https://github.com/phmatray/ai-migration-kit ~/.ai-migration-kit
mkdir -p .cursor/rules &amp;&amp; cp ~/.ai-migration-kit/.cursor/rules/ai-migration-kit.mdc .cursor/rules/</code></pre></div></div>
<p>That second line is Cursor's. Windsurf, Cline, Kiro, GitHub Copilot and every <code>AGENTS.md</code> host have their own on the <a href="{{ 'install.html' | relative_url }}">Install</a> page.</p>
</div>
</div>

Every host and how to remove the kit again: [Install](install.md); what each one gets:
[Platforms](platforms.md).

## Which command?

| Situation | Reach for |
|---|---|
| An idea to track | `create-issue` |
| An issue with a plan | `implement-issue #N` |
| A PR to land | `merge-pr #N` |
| One idea or issue to a merged PR, hands-off | `deliver-issue <idea>` or `#N` |
| A queue that never shrinks | `triage-backlog` |
| Many issues, hands-off | `auto-dev` |
| What went wrong in my last sessions | `review-sessions` |
| A legacy .NET app | `/migrate-assess`, then `/migrate` |
| A migrated app to re-verify | `/migrate-verify` |
| A portfolio to cost | `/migrate-audit` |
| Open follow-ups across migrated repos | `/migrate-followups` |
| A new repo for these skills | `profile-repo`, then `setup-repo` |
| Something is already broken | `debug-issue` fires on its own |

## The rest of the site

- [The methodology](methodology.md) — the two loops in full, one page per skill, the machinery, and how the kit compares to GSD, SpecKit and BMAD.
- [Decisions](decisions.md) — control-flow decisions have one program and one home.
- [Architectural Decision Records](adr/README.md) — the decisions that are hard to reverse, and the ones declined.
- [The roseline gate](roseline-gate.md) — why every C# read and write goes through RoselineMCP.
- [The bundle gate](bundle-gate.md) — the opt-in drift gate for committed bundles.
- [Demo walkthrough](demo-walkthrough.md) — a real pipeline run on the bundled legacy fixture.
- [Journal](journal/index.md) — one article per release: why it happened, what got cut, what bit us.

On GitHub: [README](https://github.com/phmatray/ai-migration-kit#readme),
[ARCHITECTURE.md](https://github.com/phmatray/ai-migration-kit/blob/main/ARCHITECTURE.md),
[CONTEXT.md](https://github.com/phmatray/ai-migration-kit/blob/main/CONTEXT.md) and the
[CHANGELOG](https://github.com/phmatray/ai-migration-kit/blob/main/CHANGELOG.md).
