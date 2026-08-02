# Wiring Apple Search Ads attribution into RevenueCat

Do this once per app (MigraineCast, Calm SOS, Truth or Dare AI, The Great Lock In
Challenge). Until it ships, keyword-level ROAS in the command center is an
**estimate** allocated from campaign spend, not a measurement.

## Why this is needed

Apple Search Ads reports spend per keyword. RevenueCat reports revenue per
customer. Nothing connects them unless your app does it at install time:

1. On first launch, `AdServices` gives you a token.
2. You exchange that token with Apple for an attribution payload containing
   `campaignId`, `adGroupId` and `keywordId`.
3. You write those onto the RevenueCat customer as subscriber attributes.
4. Every future purchase by that customer carries the keyword that bought them.

Step 3 is the one everybody skips, and it is the one that makes the join
possible.

## Requirements

- iOS 14.3+ (`AdServices` framework)
- `AdSupport` is **not** needed and no ATT prompt is required — AdServices
  attribution works without user tracking permission
- RevenueCat SDK already integrated (you have this)

## The code

Add `AdServices` to your target's linked frameworks, then drop this file in.

```swift
import Foundation
import AdServices
import RevenueCat

/// Captures Apple Search Ads attribution and forwards it to RevenueCat.
///
/// Call `ASAAttribution.captureIfNeeded()` once, as early as possible after
/// `Purchases.configure`. It is safe to call on every launch: it no-ops after
/// the first success.
enum ASAAttribution {

    private static let completedKey = "asa_attribution_captured_v1"

    static func captureIfNeeded() {
        guard #available(iOS 14.3, *) else { return }
        guard !UserDefaults.standard.bool(forKey: completedKey) else { return }

        Task.detached(priority: .utility) {
            do {
                try await capture()
                UserDefaults.standard.set(true, forKey: completedKey)
            } catch {
                // Non-fatal: a failure here costs attribution on this install,
                // never the launch. It retries on the next cold start.
                print("[ASAAttribution] capture failed: \(error)")
            }
        }
    }

    @available(iOS 14.3, *)
    private static func capture() async throws {
        // Throws on Simulator and on devices with no attribution record.
        let token = try AAAttribution.attributionToken()

        var request = URLRequest(
            url: URL(string: "https://api-adservices.apple.com/api/v1/")!)
        request.httpMethod = "POST"
        request.setValue("text/plain", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(token.utf8)

        // Apple returns 404 for a few seconds right after install while the
        // record propagates, so retry briefly before giving up.
        let payload = try await postWithRetry(request)

        guard payload["attribution"] as? Bool == true else {
            // Organic install: nothing to attribute, and recording empty
            // values would pollute the ROAS join.
            return
        }

        var attributes: [String: String] = [:]
        if let campaignId = payload["campaignId"] {
            attributes["asa_campaign_id"] = String(describing: campaignId)
        }
        if let adGroupId = payload["adGroupId"] {
            attributes["asa_ad_group_id"] = String(describing: adGroupId)
        }
        if let keywordId = payload["keywordId"] {
            attributes["asa_keyword_id"] = String(describing: keywordId)
        }
        if let countryOrRegion = payload["countryOrRegion"] as? String {
            attributes["asa_country"] = countryOrRegion
        }

        guard !attributes.isEmpty else { return }

        // These land on the RevenueCat customer and appear on every subsequent
        // webhook event for them, which is what the relay reads.
        Purchases.shared.attribution.setAttributes(attributes)
    }

    @available(iOS 14.3, *)
    private static func postWithRetry(_ request: URLRequest,
                                      attempts: Int = 4) async throws -> [String: Any] {
        var lastError: Error?
        for attempt in 0..<attempts {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0

                if status == 404 {
                    // Record not ready yet; back off and try again.
                    try await Task.sleep(nanoseconds: UInt64(pow(2.0, Double(attempt)) * 1e9))
                    continue
                }
                guard (200..<300).contains(status) else {
                    throw NSError(domain: "ASAAttribution", code: status)
                }
                guard let json = try JSONSerialization.jsonObject(with: data)
                        as? [String: Any] else {
                    throw NSError(domain: "ASAAttribution", code: -1)
                }
                return json
            } catch {
                lastError = error
                try? await Task.sleep(nanoseconds: UInt64(pow(2.0, Double(attempt)) * 1e9))
            }
        }
        throw lastError ?? NSError(domain: "ASAAttribution", code: -2)
    }
}
```

Then call it right after configuring RevenueCat:

```swift
Purchases.configure(withAPIKey: "appl_...")
ASAAttribution.captureIfNeeded()
```

## Checklist per app

- [ ] Add `AdServices.framework` to **Link Binary With Libraries** (weak-link if
      you still support iOS < 14.3)
- [ ] Add `ASAAttribution.swift` above
- [ ] Call `ASAAttribution.captureIfNeeded()` after `Purchases.configure`
- [ ] Ship, then verify: RevenueCat → a recent customer → **Attributes** should
      show `asa_keyword_id`
- [ ] In the command center, open the app's **Revenue** tab → the attribution
      badge should move from *Estimated* to *Measured* as new purchases arrive

## What to expect

- Attribution only applies to **new installs** after the update ships. Existing
  customers never get a keyword id, so coverage climbs gradually rather than
  jumping to 100%.
- Organic installs correctly have no keyword id. Coverage well below 100% is
  normal and healthy — it is the paid share that matters.
- Testing on Simulator always fails (`AAAttribution.attributionToken()` throws);
  test on a real device.
