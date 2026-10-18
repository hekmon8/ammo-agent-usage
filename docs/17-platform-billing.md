# Platform balances, spending and alerts

Ammo keeps each account, metric and currency separate. A wallet balance is money
remaining; usage spending is money already consumed. A user-entered budget is a
local alert threshold, not a provider credit limit. No combined wallet total,
exchange-rate conversion or automatic recharge is performed.

## Connect on the collecting Mac

Open **Accounts & Services**, add the provider, and paste the appropriate key.
Credentials remain in the existing app-owned Keychain; synced snapshots contain
only normalized metrics and opaque account identifiers.

| Provider | Setup | Displayed metric | Boundary |
| --- | --- | --- | --- |
| OpenRouter | Management API key | Prepaid balance (`total_credits - total_usage`); existing key cap when available | A normal inference key may not read account credits |
| fal | Admin API key | Current prepaid credits, with reported currency | An inference-only key cannot read account billing |
| Cloudflare | Token with Account Billing Read + 32-character account ID | Current billing-period sum of `ContractedCost` | Variable charges only; excludes fixed subscriptions; daily data; v1 alpha/deprecated endpoint |
| Vercel | Billing-capable team token + `team_…` ID | UTC calendar-month Usage-category `BilledCost` | Delayed daily export; excludes purchases, taxes and credit rows; not final invoice |
| Replit Enterprise | Enterprise Admin API `rpl_…` key with `read:*` | Current-period `totalCostUsd` | Gross ledger cost before credits, discounts and adjustments; personal/Core/Pro balances unsupported |

Cloudflare has no documented period end in this response, so Ammo displays its
reported start without inventing a reset time. Vercel and Replit retain explicit
period boundaries. Empty/malformed/mixed-currency or mismatched-account data is
unavailable; it never becomes a zero bill. A reported zero cost remains a valid
money metric. HTTP 401 means authentication is required; 403 means permission is
missing. Transport is bounded and never follows credential-bearing redirects.

Replit's documented response has no enterprise ID. Its connection is scoped to a
one-way key fingerprint, as with existing credential-scoped adapters. Rotating the
key requires reconnecting and recreating rules. Two keys for one enterprise can
show duplicate usage, so amounts must not be added together.

## UI and ownership

The native Paper / Ink overview groups **Quota windows**, **Prepaid balances**,
**Usage spending**, and **Included credits**. The Mac adds account search, a metric
filter, compact rows, an attention summary and a native inspector. The iPhone uses
the same rows with a details sheet. Input order is stable inside each section.
Money uses an explicit currency; only genuine quota ratios receive a quota ruler.
Freshness and the provider's cost scope remain visible.

The UI specification was produced with Claude Opus 5.5 using a bounded brief of
existing native design tokens and metric requirements. Codex implemented and
verified the SwiftUI code. Adopted: compact grouped ledger rows, native inspector
and phone sheet, independent currencies, stale-state labels and opt-in alerts.
Integration choices: two severity thresholds, additional confirmed billing APIs,
and the existing localized money formatter instead of a USD-only presentation.

## Alerts

Open a metric on the Mac and save a rule. Suggested values are editable drafts;
they do not enable a rule until saved. Balance/allowance warnings trigger at or
below the entered amount; spending warnings trigger at or above the entered
amount. A spending rule's critical amount is the user's budget. Quota rules use
remaining percent. Warning and critical thresholds must be ordered correctly.

The **Alerts** page controls rules and opt-in Mac notifications. Rules and a
pending notification ledger are written atomically under the app's local support
directory (`billing/state.json`, owner-only directory/file permissions). Existing
unsafe or unreadable files are rejected without overwriting them; this is the initial
rules format, with no legacy-format migration. Delivery is attempted after persistence; failed delivery retries on a
fresh observation, including after restart. Notification identifiers are stable
per metric. Unchanged severity does not repeatedly notify; recovery rearms the
rule and a more severe threshold can notify again. A newer billing-period start
rearms period alerts; a late older period cannot rewind that ledger.

Stale, failed, future-dated, disabled, estimated or currency-mismatched observations
never trigger a new notification or rearm a rule. Recovery, rule edits/removal,
and turning notifications off clear obsolete pending/delivered notifications.
Delivery after a crash is at-least-once with the same OS notification identifier.
Mac notification permission, Focus and system settings still govern presentation.

Ammo must be running on the Mac to fetch and evaluate rules. This version does not
sync alert preferences or send billing push alerts to iPhone. The phone displays
synced amounts and their freshness. No new Worker or APNs deployment is needed.

## Validation and upstream references

Synthetic tests cover provider parsing, account/currency isolation, zero versus
missing, normalized snapshot encoding, stale/failure suppression, crossing and
escalation, old-period rejection, persistence, notification retry and cleanup.
Native screenshot fixtures are synthetic. These checks do not prove a real key's
permission or a platform's live response for a particular account.

Official contracts checked on 2026-09-26:

- [fal account billing](https://fal.ai/docs/platform-apis/v1/account/billing)
- [OpenRouter credits](https://openrouter.ai/docs/api/api-reference/credits/get-remaining-credits)
- [Cloudflare billable usage v1](https://developers.cloudflare.com/api/resources/billing/subresources/usage/methods/get_account_usage_v1/)
- [Cloudflare billing scope](https://developers.cloudflare.com/billing/manage/billable-usage/)
- [Vercel FOCUS billing charges](https://vercel.com/docs/rest-api/billing/list-focus-billing-charges)
- [Replit Enterprise Admin API](https://docs.replit.com/teams/admin-api)
- [Replit API schemas](https://api.replit.com/docs)
