# Acme launch (`acme-api` + `acme-web` + `acme-site`)

**Status: promoted on 2026-09-11 by a `corrections_only` exit at round 3, and nothing
has launched yet.** The plan is a fixture for wf-plan-lint.test.sh; of its 14 nodes, 9 are PRs, 3 are
things the conductor does from its own session, and 2 are the owner's.

**Phase 1 — Before launch**

- **manual-1** The owner creates the GitHub organization — not started
- **api-1** `feat(auth): sessions expire after a week` — not started
- **api-2** `fix(auth): a refresh after expiry signs the user out` — not started, needs `api-1`
- **web-1** `feat(auth): the expired-session banner` — not started, needs `api-2`
- **manual-5** The owner adds the deploy hook secret — not started, needs `manual-1`
- **api-3** `ci: deploy on merge` — not started, needs `manual-5`
- **api-4** `test(db): the suite builds its own database` — not started, needs `api-3`

**Phase 2 — Launch**

- **setup-1** The site's DNS points at the host — not started, needs `api-4`
- **api-6** `docs: the self-hosting guide` — not started, needs `setup-1`
- **api-8** `chore: the release workflow` — not started, needs `api-6`
- **web-2** `feat: the landing page names the release` — not started, needs `api-8`
- **site-1** `docs: the front page` — blocked: the owner's ruling on the domain
- **setup-2** The repositories go public — not started, needs `web-2`, `site-1`
- **setup-3** The announcement is scheduled — not started, needs `setup-2`

**Owner decisions, 2026-09-07** — a cap whose open findings each carry a single evident
resolution is folded and the loop re-entered without a gate; after two more rounds the
plan is promoted by ruling, its open findings recorded as open.

## State

```yaml
repos: [acme-api, acme-web, acme-site]
nodes:
  # ---- Phase 1: before launch ----
  - id: manual-1
    kind: manual
    title: "The owner creates the GitHub organization"
    needs: []
    agent: owner
    status: pending
    check: "gh api orgs/acme answers 200"
  - id: api-1
    repo: acme-api
    title: "feat(auth): sessions expire after a week"
    needs: []
    agent: implementer-high
    status: pending
  - id: api-2
    repo: acme-api
    title: "fix(auth): a refresh after expiry signs the user out"
    needs: [api-1]
    agent: implementer
    status: pending
  - id: web-1
    repo: acme-web
    title: "feat(auth): the expired-session banner"
    needs: [api-2]
    agent: implementer
    status: pending
  - id: manual-5
    kind: manual
    title: "The owner adds the deploy hook secret"
    needs: [manual-1]
    agent: owner
    status: pending
    check: "gh secret list -R acme/acme-api names DEPLOY_HOOK"
  - id: api-3
    repo: acme-api
    title: "ci: deploy on merge"
    needs: [manual-5]
    agent: implementer
    status: pending
  - id: api-4
    repo: acme-api
    title: "test(db): the suite builds its own database"
    needs: [api-3]
    agent: implementer
    status: pending
  # ---- Phase 2: launch ----
  - id: setup-1
    kind: setup
    title: "The site's DNS points at the host"
    needs: [api-4]
    agent: conductor
    status: pending
    check: "dig +short acme.example answers the host's address"
  - id: api-6
    repo: acme-api
    title: "docs: the self-hosting guide"
    needs: [setup-1]
    agent: implementer
    status: pending
  - id: api-8
    repo: acme-api
    title: "chore: the release workflow"
    needs: [api-6]
    agent: implementer
    status: pending
  - id: web-2
    repo: acme-web
    title: "feat: the landing page names the release"
    needs: [api-8]
    agent: implementer
    status: pending
  - id: site-1
    repo: acme-site
    title: "docs: the front page"
    needs: []
    agent: implementer
    status: blocked
    reason: "the owner's ruling on the domain"
  - id: setup-2
    kind: setup
    title: "The repositories go public"
    needs: [web-2, site-1]
    agent: conductor
    status: pending
    check: "gh repo view acme/acme-api --json visibility reports PUBLIC"
  - id: setup-3
    kind: setup
    title: "The announcement is scheduled"
    needs: [setup-2]
    agent: conductor
    status: pending
    check: "the scheduled post exists"
```

## Review history

- **2026-09-10, round 1 — `revise`.** The sequencing pass found the deploy secret
  needed before the workflow that reads it; folded as a `needs` edge.
- **2026-09-10, round 2 — `revise`.** A citation into the release workflow had moved;
  folded, and the cap routed by the owner's recorded policy.
- **2026-09-11, round 3 — `corrections_only`.** Prose corrections, each validated.

## Build order

The auth work lands first because the banner reads what the expiry writes. The deploy
workflow waits on the owner's secret, and the public flip waits on everything else.
