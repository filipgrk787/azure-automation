This repository contains a single operational script that manages Azure Front Door (Azure Front Door for CDN / AFD) origins and endpoint purges.

Keep guidance short and actionable. Focus on the `frontdoor-switch.sh` script: how it enumerates subscriptions/resource-groups/profiles, filters results, and runs bulk updates and purges using the Azure CLI.

What this project is and why
- Purpose: a single Bash utility to select Azure subscription + resource group(s), find Azure Front Door (AFD) profiles, toggle origin enabled-state by origin priority, and optionally purge custom domains.
- Why it exists: automate operational tasks across multiple AFD profiles and endpoints, including parallelized origin updates and content purges.

Key files to read first
- `frontdoor-switch.sh` — the entire behaviour lives here. Read top-to-bottom; most logic is interactive (select menus + read prompts). Use this file as the authoritative source for command structure and patterns.

Architecture & data flow (high level)
- Input: interactive prompts (subscription selection, resource-group selection or "Not Sure", profile selection(s), origin priority, desired state, purge confirmation).
- Discovery: uses `az` CLI calls to list subscriptions, resource groups, AFD profiles (`az afd profile list`), origin-groups (`az afd origin-group list`), origins (`az afd origin list`) and endpoints/routes/custom-domains.
- Transform: filters subscription and resource-group names (skips RG names with known prefixes), extracts origin IDs for a specific priority value using an `--query` JMESPath expression, and deduplicates domains while excluding `azurefd.net`.
- Actions: updates origins with `az afd origin update --ids <id> --enabled-state <state>` (backgrounded and waited on), and purges endpoints with `az afd endpoint purge` (also parallelized).

Important patterns & conventions
- Interactive-first: the script is designed for interactive use (bash `select`, `read -p`). If you add automation or tests, provide non-interactive options or environment variables.
- Filtering regexes: resource groups with prefixes like `MC_`, `ResourceMoverRG`, `AzureBackupRG`, `NetworkWatcherRG`, `LogAnalyticsDefaultResources`, `ai_`, `Default-ActivityLogAlerts` are ignored. Reuse the same patterns when adding new discovery code.
- Azure CLI & JMESPath: many operations use `--query` to filter server-side (e.g., `[?priority==\`1\`].id`). Preserve JMESPath style and escaping when editing.
- CRLF handling: the script repeatedly strips `\r`/newlines from CLI output (e.g., `tr -d '\r'` and `tr -d '\r\n'`) — keep these to avoid Windows carriage-return problems.
- Parallel execution: updates and purges are run in background jobs (`&`) and `wait`ed. Keep output ordering and error counting in mind when changing concurrency.

How to run (developer notes)
- Prerequisites: Azure CLI installed and logged in (run `az login`), Bash available (Git Bash / WSL / Linux). The script assumes `az afd` commands are available (Azure Front Door extension or proper Azure CLI version).
- Typical run (interactive):
  1. Ensure you're authenticated: `az login` and `az account set --subscription <id>` (the script will also prompt to select).
  2. Start the script from a Bash shell: `./frontdoor-switch.sh` (make it executable if needed: `chmod +x frontdoor-switch.sh`).

Debugging & modification tips
- To inspect what the script will change without making updates, run discovery steps manually using the same `az ... --query` calls from `frontdoor-switch.sh` and print results.
- When changing queries, validate them interactively in a terminal before committing. Example check for origin IDs of priority 1:
  az afd origin list --profile-name <profile> --origin-group-name <group> --resource-group <rg> --query "[?priority==\`1\`].id" -o tsv
- If you add non-interactive flags, keep current behavior as default to avoid breaking operators who run the script manually.

Edge-cases and gotchas discovered here
- No guard rails: the script will call `az afd origin update` in parallel for every matched origin. There is no rate-limiting or retry logic. Expect possible transient failures if Azure throttles requests.
- Multi-OS caution: original script strips `\r` characters — if you run on Windows-native bash with CRLF output, keep those strips. When porting to pure PowerShell, rewrite these sanitizations.
- Ambiguous subscription names: the script intentionally filters out two subscription names; follow that pattern if you add filtering.

When opening PRs / making changes
- Keep changes minimal and focused. Update the top comment of `frontdoor-switch.sh` if you adjust behavior that changes run instructions.
- Add small, reproducible tests if you add logic (sample: helper that parses CLI output -> unit test using saved sample CLI output). Prefer shell unit testing frameworks (bats) or convert parsing helpers to a small Python script with pytest.

Examples (copy-paste patterns to reuse)
- Extract origin IDs by priority:
  az afd origin list --profile-name "$profile" --origin-group-name "$group" --resource-group "$rg" --query "[?priority==\`$keyword\`].id" -o tsv
- Parallel update pattern (preserve `&` + `wait`):
  while IFS= read -r origin_id; do
    az afd origin update --ids "${origin_id}" --enabled-state "${state}" &
  done <<< "$all_origin_ids"
  wait

If you need more detail
- Tell me what you want the bot to help with (editing the script, adding non-interactive flags, converting to PowerShell, adding tests). I can expand the instructions or update the script directly.

---
If this file should be merged with an existing `.github/copilot-instructions.md`, prefer preserving any higher-level organizational policy text and append these script-specific sections under "Repository-specific guidance".
