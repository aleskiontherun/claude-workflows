#!/usr/bin/env bash
# Check one plan against the shape ~/.claude/wf/reference/plan-format.md defines: the
# `## State` block, the Status ledger and prose that mirror it, and the DRAFT marker.
#
#   wf-plan-lint.sh <plan.md>
#
# Prints `FAIL <check>: <what>`, one line per failure, then a summary line naming the
# first failing check, and exits 1. Exits 0 with a one-line summary when everything holds.
# The checks, in the order the summary ranks them:
#
#   state-block  `## State` is followed by a ```yaml fence, closed before the next heading
#   indent       every `- id:` line sits at 2 spaces and every node field at 4. Checked on
#                the text, before parsing: a whole block shifted by two parses cleanly, and
#                one shifted node parses as an error reported against the node above it
#   state-parse  the block is YAML and carries a `nodes` list. `delivered:` items are
#                blanked first: they are an implementer's report copied verbatim, free
#                text rather than YAML, and nothing here reads them
#   ids-unique   every node has an id and no two share one
#   needs-exist  every `needs` entry names a node
#   dag-order    every node comes after the nodes it needs
#   kind         a PR node (no `kind`) has `repo`, `agent`, `title` and no `check`; a
#                `setup` node has `agent: conductor`, a `check` and no `repo`; a `manual`
#                node the same with `agent: owner`; every node has a `title`
#   status       one of the format's eight; `done` only on setup/manual, `merged`, `open`
#                and `draft-pr` only on PR nodes
#   ledger       the `- **<id>**` bullets between the `**Status:` line and `## State` are
#                the block's ids, in the block's order -- and, when wf-plan-ledger.sh sits
#                beside this script, the ledger is byte for byte what it renders from the
#                block: the ledger is generated, never written. That script's own refusals
#                (a `merged` node with no `sha`, an `open` one with no `pr`) are reported
#                here too. The rendering is made against the plan's own workspace root, so
#                its links are the ones --write would produce in place
#   counts       where the Status says "of its N nodes, P are PRs, S are the conductor's,
#                M are the owner's", each figure it states matches the block
#   round        where the Status says "round N is in flight", the last round entry in
#                `## Review history` is round N-1 ("the first round is in flight": none)
#   draft        a Status that says promoted or ready to implement carries no DRAFT; a
#                Status carrying DRAFT has `## Open questions for the detailing pass` or a
#                `## State` block (the shallow park)
#   self-count   no number, digit or word, sits before one of the plan's own nouns --
#                "five rules", "the six owner decisions", "ten nodes" -- outside
#                `## Review history`, a numbered item and its continuation lines, a
#                `delivered:` report, the Status roster the `counts` check owns, and a
#                reference like "Phase 3 nodes" or "PR 2" where the number belongs to the
#                word before it. Matched over the lines joined, because the phrase
#                wraps. plan-format.md (*Counts*) says why
#
# A plan with no `## State` block gets the last three only: drafts never have one, and a
# plan that never had nodes keys its ledger by repo. A file with no `**Status:` line is a
# strategy document and passes.
#
# Why each check exists is plan-format.md's to say, and
# ~/.claude/wf/reference/plan-review-loop.md says when to run this: before every review
# round, every fold-checker spawn and every commit of a plan. Run from memory, these
# checks get skipped before a fold, which is where they catch the most.
#
# Exit status: 0 ok; 1 a check failed; 2 the plan cannot be read, or ruby is missing; 64
# usage. Needs bash and ruby (the system /usr/bin/ruby is enough) and a UTF-8 locale,
# which the exec line sets: without it psych dies on the first em-dash in a plan. The
# block is read with `safe_load`, dates permitted, so it behaves the same on Psych 3 and
# on Psych 4; it is parsed for its shape only -- a digit-only `sha` reads as a number
# here, which is why wf-plan-ledger.sh parses the text itself, and nothing below looks at
# a sha's value. wf-plan-lint.test.sh beside this file mutates a fixture plan into a
# failure for every check and asserts which check fires first.

set -u

if [ "$#" -ne 1 ]; then
  printf 'usage: %s <plan.md>\n' "${0##*/}" >&2
  exit 64
fi
plan=$1
if [ ! -f "$plan" ] || [ ! -r "$plan" ]; then
  printf 'wf-plan-lint: cannot read %s\n' "$plan" >&2
  exit 2
fi
command -v ruby >/dev/null || { printf 'wf-plan-lint: ruby is required\n' >&2; exit 2; }

wf_here() { # this script's directory, symlinks resolved
  local s=${BASH_SOURCE[0]} d
  while [ -L "$s" ]; do
    d=$(cd -P -- "$(dirname -- "$s")" && pwd)
    s=$(readlink -- "$s"); case $s in /*) ;; *) s=$d/$s ;; esac
  done
  cd -P -- "$(dirname -- "$s")" && pwd
}
here=$(wf_here)

# The generator's verdict on the ledger, settled here because it is a shell script: its
# --write on a copy either reproduces the plan (fresh), changes it (stale), or refuses
# (error, with its reason). The copy is what keeps a lint from ever writing the plan, and
# WF_WORKSPACE pins the copy to the plan's own workspace root -- a copy in a temp dir
# would otherwise resolve no checkouts and render every link bare.
ledger=absent
generator=$here/wf-plan-ledger.sh
if [ -x "$generator" ] && [ -r "$here/wf-lib.sh" ]; then
  # shellcheck source=SCRIPTDIR/wf-lib.sh
  . "$here/wf-lib.sh"
  root=${WF_WORKSPACE:-$(wf_root "$plan")}
  copy=$(mktemp) || exit 2
  cp -- "$plan" "$copy" || exit 2
  if out=$(WF_WORKSPACE=$root "$generator" "$copy" --write 2>&1); then
    if cmp -s -- "$copy" "$plan"; then ledger=fresh; else ledger=stale; fi
  else
    ledger="error: $out"
  fi
  rm -f -- "$copy"
fi

LC_ALL=en_US.UTF-8 exec ruby -Eutf-8:utf-8 -ryaml -rdate - "$plan" "$ledger" "$generator" <<'RUBY'
path = ARGV[0]
generator = ARGV[1]
generator_path = ARGV[2]
lines = File.read(path, encoding: "UTF-8").split("\n", -1)
lines.pop if lines.last == ""

CHECKS = %w[state-block indent state-parse ids-unique needs-exist dag-order kind status
            ledger counts round draft self-count].freeze
STATUSES = %w[pending done running open draft-pr merged blocked dropped].freeze
FIELDS = %w[id kind repo title needs agent status branch pr sha merged reason delivered check].freeze

failures = []
add = ->(check, msg) { failures << [check, msg] }
present = ->(v) { v.is_a?(String) && !v.strip.empty? }

# --- the regions: the Status paragraph, the preamble, the block ---------------------
h2_after = ->(from) { (from...lines.size).find { |i| lines[i].start_with?("## ") } }
status_i = lines.index { |l| l.start_with?("**Status:") }
state_i = lines.index { |l| l.rstrip == "## State" }
first_h2 = h2_after.(0)

status_para = ""
preamble = ""
if status_i
  para_end = (status_i...lines.size).find { |i| lines[i].strip.empty? } || lines.size
  status_para = lines[status_i...para_end].join(" ")
  preamble = lines[status_i...(first_h2 || lines.size)].join(" ")
end

block = nil
block_start = nil # 1-based file line of the block's first line
if state_i
  stop = h2_after.(state_i + 1) || lines.size
  open_i = (state_i + 1...stop).find { |i| lines[i] =~ /\A```yaml\s*\z/ }
  if open_i.nil?
    add.("state-block", "no ```yaml fence under ## State (line #{state_i + 1})")
  else
    close_i = (open_i + 1...stop).find { |i| lines[i] =~ /\A```\s*\z/ }
    if close_i.nil?
      add.("state-block", "the ```yaml fence at line #{open_i + 1} is not closed before the next heading")
    else
      block = lines[(open_i + 1)...close_i]
      block_start = open_i + 2
    end
  end
end

# --- indent: on the text, one line per misplaced node --------------------------------
if block
  node_ln = nil
  reported = {}
  block.each_with_index do |l, i|
    ln = block_start + i
    if (m = l.match(/\A( *)- id:/))
      node_ln = ln
      if m[1].size != 2
        add.("indent", "line #{ln}: `- id:` at #{m[1].size} spaces; a node starts at 2")
        reported[node_ln] = true
      end
    elsif (m = l.match(/\A( +)(#{FIELDS.join('|')}):/)) && m[1].size != 4
      next if reported[node_ln]
      reported[node_ln] = true
      add.("indent", "line #{ln}: `#{m[2]}:` at #{m[1].size} spaces; a node's fields sit at 4")
    end
  end
end

# --- state-parse ------------------------------------------------------------------------
#
# `delivered:` items are an implementer's report copied verbatim (plan-format.md), and
# free text is not YAML: a signature carrying `: ` twice is a parse error. Nothing here
# reads them, so every line nested under the field is blanked -- blanked rather than
# dropped, so a parse error further down still names its file line.
nodes = nil
if block
  parsed = []
  under_delivered = false
  block.each do |l|
    if l =~ /\A {4}delivered:\s*\z/
      under_delivered = true
    elsif under_delivered && (l =~ /\A {5,}/ || l.strip.empty?)
      parsed << ""
      next
    else
      under_delivered = false
    end
    parsed << l
  end
  data = nil
  begin
    # safe_load with Date permitted reads the same on Psych 3 and on Psych 4, where
    # ruby 3.1+ made safe the default and `merged: 2026-09-07` would otherwise raise.
    data = YAML.safe_load(parsed.join("\n") + "\n", permitted_classes: [Date])
  rescue Psych::SyntaxError => e
    add.("state-parse", "line #{block_start + e.line - 1}: #{e.problem} #{e.context}".rstrip)
  rescue Psych::Exception => e
    add.("state-parse", e.message)
  else
    if !data
      add.("state-parse", "the block is empty")
    elsif !(data.is_a?(Hash) && data["nodes"].is_a?(Array) && data["nodes"].all? { |n| n.is_a?(Hash) })
      add.("state-parse", "the block is not a mapping with a `nodes` list of mappings")
    else
      nodes = data["nodes"]
    end
  end
end

counts = { "pr" => 0, "setup" => 0, "manual" => 0 }
ids = []
if nodes
  # --- ids-unique -----------------------------------------------------------------------
  label = ->(n, k) { present.(n["id"]) ? "`#{n['id']}`" : "node #{k + 1}" }
  pos = {}
  nodes.each_with_index do |n, k|
    if present.(n["id"])
      add.("ids-unique", "`#{n['id']}` appears twice") if pos.key?(n["id"])
      pos[n["id"]] ||= k
      ids << n["id"]
    else
      add.("ids-unique", "#{label.(n, k)} has no `id`")
    end
  end

  # --- needs-exist, dag-order -----------------------------------------------------------
  nodes.each_with_index do |n, k|
    who = label.(n, k)
    unless n["needs"].is_a?(Array)
      add.("needs-exist", "#{who} has no `needs` list (write `needs: []`)")
      next
    end
    n["needs"].each do |d|
      unless d.is_a?(String) && pos.key?(d)
        add.("needs-exist", "#{who} needs `#{d}`, which is not a node")
        next
      end
      if d == n["id"]
        add.("dag-order", "#{who} needs itself")
      elsif pos[d] > k
        add.("dag-order", "#{who} needs `#{d}`, which is listed after it; nodes go in DAG order")
      end
    end
  end

  # --- kind, status ---------------------------------------------------------------------
  nodes.each_with_index do |n, k|
    who = label.(n, k)
    kind = n["kind"]
    case kind
    when nil
      counts["pr"] += 1
      add.("kind", "#{who} is a PR node and has no `repo`") unless present.(n["repo"])
      add.("kind", "#{who} is a PR node and has no `agent`") unless present.(n["agent"])
      add.("kind", "#{who} is a PR node and carries a `check:`; only setup and manual nodes do") if n.key?("check")
    when "setup", "manual"
      counts[kind] += 1
      agent = kind == "setup" ? "conductor" : "owner"
      add.("kind", "#{who} is a #{kind} node and needs `agent: #{agent}`, not `#{n['agent']}`") unless n["agent"] == agent
      add.("kind", "#{who} is a #{kind} node and has no `check:`") unless present.(n["check"])
      add.("kind", "#{who} is a #{kind} node and carries a `repo`; it has none") if n.key?("repo")
    else
      add.("kind", "#{who} has `kind: #{kind}`; the kinds are setup and manual, and a PR node omits the field")
    end
    add.("kind", "#{who} has no `title`") unless present.(n["title"])

    st = n["status"]
    if st.nil?
      add.("status", "#{who} has no `status`")
    elsif !STATUSES.include?(st)
      add.("status", "#{who} has `status: #{st}`; the statuses are #{STATUSES.join(', ')}")
    elsif st == "done" && kind.nil?
      add.("status", "#{who} is a PR node marked `done`; a PR node ends at `merged`")
    elsif %w[merged open draft-pr].include?(st) && !kind.nil?
      add.("status", "#{who} is a #{kind} node marked `#{st}`; a #{kind} node ends at `done`")
    end
  end

  # --- ledger ---------------------------------------------------------------------------
  if status_i.nil?
    add.("ledger", "the plan has a ## State block but no **Status: paragraph to carry its ledger")
  else
    ledger = lines[status_i...state_i].map { |l| l[/\A- \*\*([a-z][a-z0-9-]*-[0-9]+[a-z]*)\*\*/, 1] }.compact
    if ledger != ids
      missing = ids - ledger
      extra = ledger - ids
      if missing.any? || extra.any?
        parts = []
        parts << "missing #{missing.map { |x| "`#{x}`" }.join(', ')}" if missing.any?
        parts << "extra #{extra.map { |x| "`#{x}`" }.join(', ')}" if extra.any?
        add.("ledger", "the ledger's ids differ from the block's: #{parts.join('; ')}")
      else
        k = ledger.each_index.find { |i| ledger[i] != ids[i] }
        add.("ledger", "the ledger leaves block order at bullet #{k + 1}: it has `#{ledger[k]}`, the block has `#{ids[k]}`")
      end
    elsif generator == "stale"
      add.("ledger", "the ledger is not wf-plan-ledger.sh's rendering of the block; run `#{generator_path} #{path} --write`")
    elsif generator.start_with?("error: ")
      generator.delete_prefix("error: ").each_line do |l|
        add.("ledger", "wf-plan-ledger.sh refuses the block: #{l.strip.sub(/\Awf-plan-ledger: \S+: /, '')}")
      end
    end
  end

  # --- counts ---------------------------------------------------------------------------
  said = {
    "nodes" => preamble[/\bof its (\d+) nodes\b/i, 1],
    "are PRs" => preamble[/\b(\d+) are PRs\b/, 1],
    "are the conductor's" => preamble[/\b(\d+) are (?:the conductor['’]s|things the conductor does)/, 1],
    "are the owner's" => preamble[/\b(\d+) are the owner['’]s/, 1],
  }
  actual = {
    "nodes" => nodes.size, "are PRs" => counts["pr"],
    "are the conductor's" => counts["setup"], "are the owner's" => counts["manual"],
  }
  said.each do |what, v|
    next if v.nil? || v.to_i == actual[what]
    add.("counts", "the Status says #{v} #{what}; the block has #{actual[what]}")
  end
end

# --- round ------------------------------------------------------------------------------
in_flight = nil
if (m = preamble.match(/\bround (\d+) is in flight\b/i))
  in_flight = m[1].to_i
elsif preamble =~ /\bthe first (?:`plan-reviewer` )?round is in flight\b/i
  in_flight = 1
end
if in_flight
  last = 0
  if (rh_i = lines.index { |l| l.rstrip == "## Review history" })
    stop = h2_after.(rh_i + 1) || lines.size
    lines[(rh_i + 1)...stop].each do |l|
      head = l[/\A- \*\*(.*?)\*\*/, 1] or next
      r = head[/\bround (\d+)\b/i, 1]
      last = r.to_i if r
    end
  end
  if last != in_flight - 1
    have = last.zero? ? "records no round" : "ends at round #{last}"
    add.("round", "the Status says round #{in_flight} is in flight, but ## Review history #{have}")
  end
end

# --- draft ------------------------------------------------------------------------------
if status_i
  draft = status_para =~ /\bDRAFT\b/
  promoted = status_para =~ /\bready to implement\b/i ||
             status_para =~ /(?<![\w-])(?<!not )(?<!not yet )(?<!never )promot(?:ed|ion)\b/i
  add.("draft", "the Status names a promotion and carries the DRAFT marker") if draft && promoted
  if draft && state_i.nil? && lines.none? { |l| l.rstrip == "## Open questions for the detailing pass" }
    add.("draft", "the Status carries DRAFT but the plan has neither ## Open questions for the detailing pass nor a ## State block")
  end
end

# --- self-count -------------------------------------------------------------------------
#
# Only a plan is checked: a file with no Status line is a strategy document. Blanked
# before matching: ## Review history, a numbered item with its indented continuation
# lines (an owner decision is preserved verbatim and may count what it ruled on), and
# `delivered:` items, which are free text (see state-parse). Skipped at the match: the
# Status roster, a number that belongs to the word before it ("Phase 3 nodes", "wave 3",
# "decision 7 step 2"), a noun used as an adjective ("node-repo", "node repos"), and a
# number that is the tail of a longer one or of a date ("2026-09-02 review round").
if status_i
  SELF_NUMS = %w[two three four five six seven eight nine ten eleven twelve thirteen
                 fourteen fifteen sixteen seventeen eighteen nineteen twenty].freeze
  SELF_NOUNS = %w[rule decision round node scenario step correction finding pass wave
                  question invariant derivation sweep gate phase PR].freeze
  SELF_ADJ = %w[open owner design review blocking checkable remaining new other].freeze
  SELF_PLURAL = { "PR" => "PRs", "pass" => "passes" }.freeze
  kept = []
  in_hist = false
  numbered = false
  under_delivered = false
  lines.each do |l|
    in_hist = true if l.start_with?("## Review history")
    in_hist = false if l.start_with?("## ") && !l.start_with?("## Review history")
    numbered = if l =~ /\A\s*\d+\.\s/ then true
               elsif numbered && l =~ /\A\s{2,}\S/ then true
               else false
               end
    under_delivered = if l =~ /\A {4}delivered:\s*\z/ then true
                      elsif under_delivered && (l =~ /\A {5,}/ || l.strip.empty?) then true
                      else false
                      end
    kept << (in_hist || numbered || under_delivered ? "" : l)
  end
  self_text = kept.join("\n")
  self_starts = []
  o = 0
  kept.each { |k| self_starts << o; o += k.size + 1 }
  self_re = /(?<![\d.,#-])\b(#{SELF_NUMS.join('|')}|\d+)\s+(?:(?:#{SELF_ADJ.join('|')})\s+)?(#{SELF_NOUNS.join('|')})(?:es|s)?\b(?!-)/i
  self_text.scan(self_re) do
    m = Regexp.last_match
    pre = self_text[0...m.begin(0)]
    next if pre =~ /\bof\s+its\s+\z/i
    next if pre =~ /(?:\bphase|\bwave|\bround|\bdecision|\bstep|\bscenario|\brule|\bnode|\bpr|§)[-\s]*\z/i
    next if m.post_match =~ /\A\s+repos?\b/i
    ln = self_starts.rindex { |s| s <= m.begin(0) } + 1
    phrase = m[0].gsub(/\s+/, " ")
    noun = SELF_PLURAL.fetch(m[2]) { "#{m[2].downcase}s" }
    add.("self-count", "line #{ln}: \"#{phrase}\" — a count of the plan's own contents; write \"the #{noun}\" and let the reader count (plan-format.md, *Counts*)")
  end
end

# --- the verdict ------------------------------------------------------------------------
rank = CHECKS.each_with_index.to_h
failures = failures.each_with_index.sort_by { |(c, _), i| [rank[c], i] }.map(&:first)
if failures.empty?
  if nodes
    puts "wf-plan-lint: ok #{path} — #{nodes.size} nodes (#{counts['pr']} pr, #{counts['setup']} setup, #{counts['manual']} manual)"
  else
    puts "wf-plan-lint: ok #{path} — no ## State block"
  end
  exit 0
end
failures.each { |c, m| puts "FAIL #{c}: #{m}" }
puts "wf-plan-lint: FAIL #{failures[0][0]} — #{failures.size} failure#{'s' if failures.size > 1} in #{path}"
exit 1
RUBY
