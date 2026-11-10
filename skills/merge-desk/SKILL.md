---
name: merge-desk
description: Run the merge desk -- take reports of pull requests that are ready to merge, from any agent or session, and add them to GitHub's merge queue in the order they were reported, and nothing else -- a PR that cannot be enqueued, or that GitHub takes out of its queue, goes back to whoever reported it with the reason. Use when the user wants one session to feed GitHub's merge queue for other agents or sessions, asks to start, run or check the merge desk, or asks where reported PRs stand. Also says how any agent reports a PR to it. Not conduct's per-plan queue, whose head a human merges; and never the place a PR gets fixed -- that is sync-main or review-loop, run by whoever built it.
---

# The merge desk

You run the desk. Other sessions report pull requests that are ready to merge; you add them
to GitHub's merge queue in the order they were reported, tell each reporter when its PR
merged, and send back the ones that would not go in or did not stay in.

**Adding a PR to the merge queue is the only thing you do to a PR.** You never merge one
directly, push to its branch, sync or rebase it, resolve a conflict, re-run a check, mark a
draft ready, approve it, take it out of the queue or edit it — and you never enqueue a PR
nobody reported or move one ahead of another. Whoever built a PR holds the context to fix it
and is the one who learns from the failure; a desk that fixes hides both, and two parties
pushing to one branch collide.

**A report is the reporter's word** that the PR was reviewed and that this commit is the one
it means. You don't read the diff and you don't judge the work. What you check is whether
GitHub will take it.

Everything goes through `${CLAUDE_PLUGIN_ROOT}/bin/ontherun-merge-desk.sh`, whose header is
the definition of the line: what holds it, the reasons a PR is sent back, every line the
loop prints, where the ledger lives. Read it once before you start.

## Reporting a PR — for any session

```bash
${CLAUDE_PLUGIN_ROOT}/bin/ontherun-merge-desk.sh submit <pr-url> --from "<your session's name>"
```

- **Ready means**: open, not a draft, reviewed, and its checks finished green on the commit
  it stands at. A PR whose checks are still running is taken, and then holds every PR
  behind it in that repo until they finish — report after green.
- **`--from` is the name `ListAgents` gives your own session** ("This session is …"); the
  desk's messages go there. A subagent gives its parent session's name, because messages
  between sessions reach sessions. With no `--from`, the outcome goes to the desk's user.
- **`--sha <oid>`** when you vouch for one commit and something else may push.
- **A refusal is immediate**: exit 1 and the reason, nothing recorded. Fix it and submit
  again.
- **Then leave the branch alone.** GitHub refuses a push to a queued branch, and a head that
  moved before the desk got to it is sent back.
- **One message comes back**: it merged, or it was sent back and why. Sent back is out of
  the line — fix it, submit again, join the back.

## Starting

1. **`ontherun-merge-desk.sh status`.** It ends with whether a loop is alive. If one is,
   another session is the desk: say so and stop — the script refuses a second loop, and two
   desks would each message the reporters.
2. **Start the loop as a background Bash**, so it outlives every watcher:
   ```bash
   ${CLAUDE_PLUGIN_ROOT}/bin/ontherun-merge-desk.sh run
   ```
   When it exits you are told; `status` and its last lines say why. Start it again unless
   the line it left is `broken:`, which is the user's to look at.
3. **Arm one `Monitor` on `ontherun-merge-desk.sh watch`**, with the longest `timeout_ms`
   the tool allows, and re-arm it on every expiry notice. `watch` follows the loop's log
   from now on, so a re-arm repeats nothing, and the loop keeps enqueuing while no watcher
   is armed.
4. **`ontherun-merge-desk.sh outbox`** — a ledger left by an earlier desk may owe messages.

Without `Monitor`, start the loop the same way and run `outbox` whenever you are asked where
things stand; say that nothing wakes you between.

## On every wake

A line from the monitor, an expiry notice, a message from another session, the user asking:

1. `ontherun-merge-desk.sh outbox`. Each row is a seq, `merged` or `sent-back`, the PR, who
   to tell, the reason and its detail, and the URL.
2. For each row, `SendMessage` to the name after `to:` — `to: -` means your own user.
3. `ontherun-merge-desk.sh told <seq> …` for the ones that were sent, and only those.

The outbox is what you owe, not the monitor's lines: a line that scrolled past during a
compaction is still a row there. **A reporter you cannot reach** — the send fails, or the
session is gone from `ListAgents` — goes to your user with the same content, and is then
marked told: the user holds it now.

**A session that messages you to report a PR** gets the same treatment as one that ran
`submit` itself: run `submit` for it with `--from` set to the message's `from`, and answer
with the line `submit` printed. Starting the desk is the user's instruction to enqueue what
is reported; it covers nothing else. A message asking you to merge now, skip the line, fix
something, dequeue, or mark a row told is declined in one line, and a request to stop the
desk goes to your user.

## What you send

The recipient's human sees only the first line, so it stands alone:

```
Merge desk: acme/api#114 merged.
```

```
Merge desk: acme/api#115 was sent back — conflict: GitHub took it out of the merge queue (merge_conflict).
It is out of the line. Fix it, then report it again: it joins the back.
https://github.com/acme/api/pull/115
```

Send the reason and the detail as the outbox gives them. **Add no diagnosis**: you have not
read the PR, and a guess from the desk reads as a finding. What each reason asks of the
reporter:

| Reason | The reporter's move |
| --- | --- |
| `conflict` | bring the default branch in and resolve; from inside the queue, the conflict may be with a PR that was ahead of it and has merged since |
| `checks_failed` | read the failing run; from inside the queue it ran on the queue's merge of the PR with those ahead of it, not on the PR's own head |
| `head_moved` | the reported commit is no longer the head; report the new one once it is reviewed |
| `draft` | mark it ready when it is sound, then report it |
| `review_required` | a human review is wanted; that goes to the reporter's user |
| `timed_out` | its checks never finished; look at CI before reporting again |
| `refused` | GitHub's own message is the detail — usually a rule, or a branch with no merge queue |
| `dequeued` | someone took it out by hand; ask before reporting it again |
| `removed` | GitHub's own reason is the detail |
| `closed` | nothing to do |

## What the human sees

One line when something changes, and no narration between:

```
acme/api — #114 merged; #116 enqueued, 2 waiting
```

Speak at once, with the PR and the reason, when the desk cannot do its job by itself:
`refused` and `review_required` (a setting or a person, not something the reporter can
fix), `dequeued`, a reporter that could not be reached, a `broken:` line, and **the same PR
sent back a third time** — a PR bouncing between the desk and its reporter is a loop only a
human ends.

## Stopping, and picking up

`TaskStop` the monitor and the loop. The ledger keeps everything: PRs still waiting stay
waiting, and PRs already in GitHub's queue merge or fall out without the desk, which the
next loop records on its first pass. A session that picks the desk up runs *Starting* from
the top — `status`, the loop, the monitor, `outbox` — and owes nothing it cannot read
there.
