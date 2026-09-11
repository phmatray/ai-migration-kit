---
title: Install
nav_order: 1.5
---

# Install

The kit is written for Claude Code and installs as a plugin on five more hosts from the same
repository. Hosts that read a rules file instead load it from a clone. Every command below carries
a copy button; what each host gets is on [Platforms](platforms.md).

## Plugin hosts

{% for host in site.data.hosts %}{% if host.tier == "plugin" %}
### {{ host.name }}

```bash
{{ host.install | join: "
" }}
```

{{ host.then }}
{% endif %}{% endfor %}

## Rule-file hosts

Clone the kit once — every rule file below routes its host to the skills in that clone:

```bash
git clone https://github.com/phmatray/ai-migration-kit ~/.ai-migration-kit
```

{% for host in site.data.hosts %}{% if host.tier == "rules" %}
### {{ host.name }}

```bash
{{ host.install | last }}
```

{{ host.then }}
{% endif %}{% endfor %}

## MCP servers

The migration pipeline runs on RoselineMCP and consults AdrMcp; both start with `dnx` from the
.NET 10 SDK. A plugin host starts them from the kit's own manifest. On a rule-file host, add them
to its MCP settings — most take this shape:

```json
{
  "mcpServers": {
    "roseline": { "command": "dnx", "args": ["RoselineMCP", "--yes"] },
    "adr": { "command": "dnx", "args": ["AdrMcp", "--yes"] }
  }
}
```

Without RoselineMCP, `/migrate` stops at its phase-0 preflight and says why; the issue → pull
request skills need neither server.

## Uninstall

{% for host in site.data.hosts %}{% if host.uninstall %}
- **{{ host.name }}** — `{{ host.uninstall }}`{% endif %}{% endfor %}
- **A rule-file host** — delete the rule file you copied, and `~/.ai-migration-kit` once no project uses it.
