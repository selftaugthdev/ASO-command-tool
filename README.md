# ASO Command Center

A personal macOS app for App Store Optimization across my four apps
(MigraineCast, Calm SOS, Truth or Dare AI, The Great Lock In Challenge).
Single user, no auth, all credentials in the macOS Keychain, all API calls made
directly from this machine to the vendor.

## Status

**Phase 1 complete and building.** 62 tests passing, app launches and renders.

| Phase 1 | State |
|---|---|
| App Store Connect auth (.p8 → Keychain → ES256 JWT) | Done |
| Metadata pull / diff / confirmed push, per locale | Done |
| Keyword research: popularity, difficulty, rank | Done |
| Rank tracking over time per app per country | Done |
| Competitor keyword estimation + overlap | Done |
| Apple Search Ads: campaigns, ad groups, bids, spend | Done |
| RevenueCat → Firestore relay + ROAS join | Done |
| Local dashboard (sidebar, tables, rank chart) | Done |

Phase 2 (alerts, iOS widget, cross-channel, content hook, MCP server) is
scaffolded in the schema — the `alerts` and `competitor_snapshots` tables and
the change-detection queries exist — but the scheduled job and UI beyond the
alerts list are not built yet.

## Requirements

- macOS 14+
- The build is pinned to the Xcode toolchain in the `Makefile`, because the
  Command Line Tools toolchain ships no XCTest. Mixing the two corrupts
  `.build`.

## Build and run

```sh
make build     # debug build
make test      # 62 tests
make app       # release .app bundle in dist/
open "dist/ASO Command Center.app"
```

## Setup order

1. **App Store Connect** — Settings → App Store Connect. Needs Issuer ID, Key ID
   and the `.p8`. The key needs **App Manager** to write metadata. Press *Test
   Connection*, then *Import Apps*.
2. **Apple Search Ads** (optional but recommended) — supplies Apple's real
   keyword popularity index. Without it, difficulty and rank still work; the
   popularity column stays empty.
3. **Firebase relay** (for revenue) — see `Firebase/` and the Revenue tab in
   Settings.
4. **AdServices attribution** — see `Docs/AdServicesAttribution.md`. Until this
   ships in your apps, keyword ROAS is *estimated*, and the app says so.

## Architecture

```
Sources/
  ASOCore/     models, Keychain, rate-limited HTTP, ES256 JWT signing
  ASOStore/    SQLite schema, migrations, all persistence
  ASCKit/      App Store Connect client, diff engine, push plans
  ASAKit/      Apple Search Ads client (OAuth2 exchange)
  KeywordKit/  iTunes Search, difficulty scoring, competitor analysis
  RevenueKit/  Firestore reader (RS256), RevenueCat mapping, ROAS join
  ASOApp/      SwiftUI dashboard
Firebase/      Cloud Function relaying RevenueCat webhooks
Docs/          AdServices attribution guide
```

## Design decisions worth knowing

**Nothing writes without confirmation.** `PushPlan.isConfirmed` starts false and
only `confirmed()` can set it; `ASCClient.push` rejects an unconfirmed plan. The
review sheet shows a before/after diff and stays disabled while the plan has
blockers (character-limit violations, or version-scoped edits with no editable
version). There is a test asserting the client refuses an unconfirmed plan.

**The metadata split.** Title, subtitle and privacy URL live on
`appInfoLocalizations`; description, keywords, promotional text, URLs and
what's-new live on `appStoreVersionLocalizations`. Different objects, different
ids, different endpoints. The differ groups changes per locale per container so
one locale costs at most two requests.

**Estimates are labelled as estimates.** Keyword difficulty is a local heuristic
(Apple publishes none). Competitor keyword sets are reconstructed from public
text (Apple does not expose a competitor's keywords field). Keyword ROAS is
measured only when purchases carry an ASA keyword id, otherwise it is allocated
by spend share and shown as *Estimated*. The Revenue tab carries a banner
stating which.

**Rank `nil` ≠ rank 0.** Falling out of the top 100 stores NULL, which is
distinct from not having checked.

## Reference material

Auth and API patterns were read from
[`ngo275/app-agent`](https://github.com/ngo275/app-agent) before writing the
App Store Connect layer. Adopted: the ES256/20-minute token shape, the
appInfo-vs-version metadata split, version-state classification, and the
`FORBIDDEN.REQUIRED_AGREEMENTS_MISSING_OR_EXPIRED` special case.

Deliberately not adopted:

- It re-signs a JWT at every call site. This caches until 60s before expiry.
- It has no 429 handling for App Store Connect (only a `// NOTE: it should have
  throttling logic` on the push route). This has a token-bucket limiter plus
  Retry-After backoff.
- Its `upsertLocalizationInfo` PATCHes to `/appInfoLocalizations/null` when a
  localization does not exist, which fails for any new locale. This POSTs with
  the parent relationship instead.
- It reads only the first page of collections. This follows `links.next`.

[`Eronred/aso-skills`](https://github.com/Eronred/aso-skills) was reviewed for
skill structure ahead of the Phase 2 MCP server.
