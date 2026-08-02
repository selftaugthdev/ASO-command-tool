import Foundation

/// Versioned schema migrations, applied in order on open.
public enum Schema {

    public static let migrations: [(version: Int, sql: String)] = [
        (1, """
        CREATE TABLE IF NOT EXISTS apps (
            id             TEXT PRIMARY KEY,
            bundle_id      TEXT NOT NULL DEFAULT '',
            name           TEXT NOT NULL,
            sku            TEXT,
            primary_locale TEXT NOT NULL DEFAULT 'en-US',
            countries      TEXT NOT NULL DEFAULT 'us',
            is_tracked     INTEGER NOT NULL DEFAULT 1
        );

        -- Metadata snapshots, so a push can always be compared with, and rolled
        -- back to, what was live before it.
        CREATE TABLE IF NOT EXISTS metadata_snapshots (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            app_id      TEXT NOT NULL REFERENCES apps(id) ON DELETE CASCADE,
            locale      TEXT NOT NULL,
            field       TEXT NOT NULL,
            value       TEXT NOT NULL,
            captured_at INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_snapshots_app_locale
            ON metadata_snapshots(app_id, locale, field, captured_at DESC);

        CREATE TABLE IF NOT EXISTS keywords (
            id         INTEGER PRIMARY KEY AUTOINCREMENT,
            app_id     TEXT NOT NULL REFERENCES apps(id) ON DELETE CASCADE,
            term       TEXT NOT NULL,
            country    TEXT NOT NULL,
            is_tracked INTEGER NOT NULL DEFAULT 1,
            added_at   INTEGER NOT NULL,
            UNIQUE(app_id, term, country)
        );

        -- One row per keyword per day. Rank is NULL when the app did not chart,
        -- which is meaningfully different from rank 0.
        CREATE TABLE IF NOT EXISTS rank_snapshots (
            id           INTEGER PRIMARY KEY AUTOINCREMENT,
            keyword_id   INTEGER NOT NULL REFERENCES keywords(id) ON DELETE CASCADE,
            rank         INTEGER,
            captured_at  INTEGER NOT NULL,
            UNIQUE(keyword_id, captured_at)
        );
        CREATE INDEX IF NOT EXISTS idx_ranks_keyword_time
            ON rank_snapshots(keyword_id, captured_at DESC);

        -- Popularity/difficulty change slowly and cost an API call, so they are
        -- cached separately from rank.
        CREATE TABLE IF NOT EXISTS keyword_metrics (
            keyword_id  INTEGER PRIMARY KEY REFERENCES keywords(id) ON DELETE CASCADE,
            popularity  REAL,
            difficulty  REAL,
            competitors INTEGER,
            source      TEXT NOT NULL DEFAULT 'unknown',
            updated_at  INTEGER NOT NULL
        );

        CREATE TABLE IF NOT EXISTS competitors (
            id           INTEGER PRIMARY KEY AUTOINCREMENT,
            app_id       TEXT NOT NULL REFERENCES apps(id) ON DELETE CASCADE,
            competitor_id TEXT NOT NULL,
            name         TEXT NOT NULL,
            country      TEXT NOT NULL DEFAULT 'us',
            added_at     INTEGER NOT NULL,
            UNIQUE(app_id, competitor_id, country)
        );

        -- Competitor metadata over time, so Phase 2 alerts can diff yesterday
        -- against today and say what actually changed.
        CREATE TABLE IF NOT EXISTS competitor_snapshots (
            id            INTEGER PRIMARY KEY AUTOINCREMENT,
            competitor_id TEXT NOT NULL,
            country       TEXT NOT NULL,
            title         TEXT,
            subtitle      TEXT,
            description   TEXT,
            version       TEXT,
            screenshot_hash TEXT,
            captured_at   INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_competitor_snapshots
            ON competitor_snapshots(competitor_id, country, captured_at DESC);

        -- Apple Search Ads spend, keyed by keyword where ASA reports it.
        CREATE TABLE IF NOT EXISTS ad_spend (
            id            INTEGER PRIMARY KEY AUTOINCREMENT,
            app_id        TEXT NOT NULL REFERENCES apps(id) ON DELETE CASCADE,
            campaign_id   TEXT NOT NULL,
            campaign_name TEXT,
            ad_group_id   TEXT,
            keyword_id    TEXT,
            keyword_text  TEXT,
            country       TEXT,
            day           INTEGER NOT NULL,
            spend         REAL NOT NULL DEFAULT 0,
            impressions   INTEGER NOT NULL DEFAULT 0,
            taps          INTEGER NOT NULL DEFAULT 0,
            installs      INTEGER NOT NULL DEFAULT 0,
            UNIQUE(app_id, campaign_id, ad_group_id, keyword_id, day)
        );
        CREATE INDEX IF NOT EXISTS idx_spend_app_day ON ad_spend(app_id, day DESC);

        -- Revenue events relayed from RevenueCat.
        CREATE TABLE IF NOT EXISTS revenue_events (
            id                INTEGER PRIMARY KEY AUTOINCREMENT,
            event_id          TEXT NOT NULL UNIQUE,
            app_id            TEXT,
            app_user_id       TEXT,
            type              TEXT NOT NULL,
            product_id        TEXT,
            store             TEXT,
            country           TEXT,
            revenue_usd       REAL NOT NULL DEFAULT 0,
            is_trial          INTEGER NOT NULL DEFAULT 0,
            occurred_at       INTEGER NOT NULL,
            -- Attribution fields, populated only when the app forwards
            -- AdServices data to RevenueCat as subscriber attributes.
            asa_campaign_id   TEXT,
            asa_ad_group_id   TEXT,
            asa_keyword_id    TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_revenue_time ON revenue_events(app_id, occurred_at DESC);
        CREATE INDEX IF NOT EXISTS idx_revenue_keyword ON revenue_events(asa_keyword_id);

        CREATE TABLE IF NOT EXISTS alerts (
            id           INTEGER PRIMARY KEY AUTOINCREMENT,
            app_id       TEXT,
            kind         TEXT NOT NULL,
            title        TEXT NOT NULL,
            body         TEXT NOT NULL,
            severity     TEXT NOT NULL DEFAULT 'info',
            created_at   INTEGER NOT NULL,
            acknowledged INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX IF NOT EXISTS idx_alerts_time ON alerts(created_at DESC);
        """),
    ]

    /// Applies any migrations newer than the database's current user_version.
    public static func migrate(_ database: Database) throws {
        let current = try database.query("PRAGMA user_version;") { $0.int(0) ?? 0 }.first ?? 0
        for migration in migrations where Int64(migration.version) > current {
            try database.execute(migration.sql)
            try database.execute("PRAGMA user_version = \(migration.version);")
        }
    }
}
