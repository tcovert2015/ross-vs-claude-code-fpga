"""Summarise one headless Claude Code run: metrics from the stream-json transcript + git stats.

usage: summarize.py <transcript.jsonl> <worktree> <design>
"""
import collections, json, subprocess, sys

transcript, wt, design = sys.argv[1:4]
tools = collections.Counter()
vivado_mcp = 0
vivado_bash = 0
result = None
with open(transcript, encoding="utf-8", errors="replace") as f:
    for line in f:
        try:
            j = json.loads(line)
        except json.JSONDecodeError:
            continue
        if j.get("type") == "assistant":
            for c in j.get("message", {}).get("content", []):
                if c.get("type") == "tool_use":
                    name = c["name"]
                    tools[name] += 1
                    if name.startswith("mcp__vivado-mcp"):
                        vivado_mcp += 1
                    if name in ("Bash", "PowerShell") and "vivado" in json.dumps(c.get("input", {})).lower():
                        vivado_bash += 1
        elif j.get("type") == "result":
            result = j

def git(*a):
    return subprocess.run(["git", "-C", wt, *a], capture_output=True, text=True).stdout.strip()

base = git("merge-base", "HEAD", "main")
commits = git("rev-list", "--count", f"{base}..HEAD")
stat = git("diff", "--shortstat", base, "HEAD", "--", f"designs/{design}")
files = git("diff", "--name-only", base, "HEAD", "--", f"designs/{design}")

print(f"# Run summary\n")
if result:
    print(f"- subtype: `{result.get('subtype')}`")
    print(f"- turns: {result.get('num_turns')}")
    print(f"- cost: ${result.get('total_cost_usd', 0):.2f}")
    print(f"- wall time: {result.get('duration_ms', 0)/60000:.1f} min (API {result.get('duration_api_ms', 0)/60000:.1f} min)")
    u = result.get("usage", {})
    print(f"- tokens: in={u.get('input_tokens')} out={u.get('output_tokens')} cache_read={u.get('cache_read_input_tokens')}")
else:
    print("- no result record (run aborted?)")
print(f"- tool calls: {sum(tools.values())}  (Vivado via MCP: {vivado_mcp}, Vivado via shell: {vivado_bash})")
print("\n| tool | calls |\n|---|---|")
for k, v in tools.most_common():
    print(f"| `{k}` | {v} |")
print(f"\n- commits on branch: {commits}\n- diff vs baseline: {stat or 'none'}\n")
print("Files changed:\n")
for p in files.splitlines():
    print(f"- `{p}`")
if result and result.get("result"):
    print("\n## Agent's final message\n")
    print(result["result"])
