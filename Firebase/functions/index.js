/**
 * RevenueCat -> Firestore relay.
 *
 * RevenueCat's REST API only supports per-customer lookups and has no bulk
 * historical event export, so the only way to build a complete event history is
 * to capture their webhooks as they arrive. This function appends each event to
 * a Firestore collection that the macOS app reads.
 *
 * Deploy:
 *   cd Firebase && firebase deploy --only functions
 *
 * Then in RevenueCat -> Project Settings -> Integrations -> Webhooks:
 *   URL:            https://<region>-<project>.cloudfunctions.net/revenuecatWebhook
 *   Authorization:  the same value you set in REVENUECAT_WEBHOOK_SECRET
 */

const { onRequest } = require("firebase-functions/v2/https");
const { defineSecret } = require("firebase-functions/params");
const admin = require("firebase-admin");

admin.initializeApp();
const db = admin.firestore();

const webhookSecret = defineSecret("REVENUECAT_WEBHOOK_SECRET");

const COLLECTION = "revenuecat_events";

/**
 * Maps a RevenueCat webhook event to the flat document shape the Mac app reads.
 *
 * Attribution ids are the point of the whole pipeline: without a keyword id,
 * ROAS can only ever be computed at campaign level. RevenueCat surfaces them
 * under subscriber_attributes when the app forwards AdServices data, so several
 * possible key spellings are checked.
 */
function toDocument(event) {
  const attributes = event.subscriber_attributes || {};

  const attribute = (...names) => {
    for (const name of names) {
      const entry = attributes[name];
      if (entry && entry.value) return String(entry.value);
    }
    return null;
  };

  // RevenueCat prefixes its own reserved attributes with `$`; ours are plain.
  const keywordId = attribute(
    "asa_keyword_id", "$keywordId", "keyword_id", "adservices_keyword_id"
  );
  const campaignId = attribute(
    "asa_campaign_id", "$campaignId", "campaign_id", "adservices_campaign_id"
  );
  const adGroupId = attribute(
    "asa_ad_group_id", "$adGroupId", "ad_group_id", "adservices_ad_group_id"
  );

  // `price` is gross; `price_in_purchased_currency` may differ by currency.
  // Prefer the USD figure RevenueCat computes so the join needs no FX rates.
  const revenueUSD =
    typeof event.price_in_usd === "number" ? event.price_in_usd
    : typeof event.price === "number" ? event.price
    : 0;

  return {
    eventId: event.id,
    type: event.type,
    appId: event.app_id || null,
    appUserId: event.app_user_id || null,
    productId: event.product_id || null,
    store: event.store || null,
    countryCode: event.country_code || null,
    revenueUSD,
    periodType: event.period_type || null,
    isTrialConversion: event.period_type === "TRIAL",
    // Firestore timestamps sort correctly and the app queries on this field.
    occurredAt: admin.firestore.Timestamp.fromMillis(
      event.event_timestamp_ms || Date.now()
    ),
    asaKeywordId: keywordId,
    asaCampaignId: campaignId,
    asaAdGroupId: adGroupId,
    receivedAt: admin.firestore.FieldValue.serverTimestamp(),
  };
}

exports.revenuecatWebhook = onRequest(
  { secrets: [webhookSecret], region: "europe-west1", cors: false },
  async (req, res) => {
    if (req.method !== "POST") {
      return res.status(405).send("Method not allowed");
    }

    // RevenueCat sends whatever you configure as the Authorization header.
    // Without this check the endpoint is an open write to your database.
    const expected = webhookSecret.value();
    if (!expected || req.get("Authorization") !== expected) {
      console.warn("Rejected webhook with bad Authorization header");
      return res.status(401).send("Unauthorized");
    }

    const event = req.body && req.body.event;
    if (!event || !event.id) {
      return res.status(400).send("Missing event");
    }

    try {
      // The document id is the event id, so RevenueCat's at-least-once delivery
      // cannot create duplicate revenue rows on retry.
      await db.collection(COLLECTION).doc(String(event.id)).set(toDocument(event), {
        merge: true,
      });
      return res.status(200).send("ok");
    } catch (error) {
      console.error("Failed to write event", event.id, error);
      // A 500 makes RevenueCat retry, which is what we want on a transient
      // Firestore failure.
      return res.status(500).send("Write failed");
    }
  }
);
