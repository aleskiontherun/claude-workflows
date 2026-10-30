# Evals

Cases for `claude plugin eval`, one directory per prompt. Each checks that a request phrased
the way a user would type it routes to the right `ontherun:` skill and not to its neighbour, and
one checks that an unrelated request routes to none. Results land in `results/`, ignored by
git.

```bash
claude plugin eval . --runs 1 --ablation none          # quick, one arm
claude plugin eval . --trust-plugin --json results.json # the CI form; see .github/workflows
```

The read-only guarantee for the review agents is tested by `hooks/readonly-guard.test.sh`,
not here: an eval that spawns those agents needs `Agent` and `Bash` grants and a repository
to review, which costs more than a hook test.
