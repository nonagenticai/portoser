#!/usr/bin/env python3
"""
Migration script for registration_tokens table
"""

import asyncio
import os
import sys

import asyncpg

# Database configuration. All values are read from the environment so the
# script works against whatever Postgres/PgBouncer the operator points it at.
DB_HOST = os.getenv("POSTGRES_HOST", "localhost")
DB_PORT = int(os.getenv("POSTGRES_PORT", "5432"))
DB_NAME = os.getenv("POSTGRES_DB", "portoser_web")
DB_USER = os.getenv("POSTGRES_USER", "postgres")
DB_PASSWORD = os.getenv("POSTGRES_PASSWORD", "postgres")


MIGRATION_SQL = """
-- Create registration_tokens table
CREATE TABLE IF NOT EXISTS registration_tokens (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    token VARCHAR(255) UNIQUE NOT NULL,
    description TEXT,
    max_uses INTEGER,
    current_uses INTEGER DEFAULT 0,
    expires_at TIMESTAMPTZ,
    created_by VARCHAR(255),
    created_at TIMESTAMPTZ DEFAULT NOW(),
    last_used_at TIMESTAMPTZ,

    -- Constraints
    CONSTRAINT check_token_uses CHECK (current_uses >= 0 AND (current_uses <= max_uses OR max_uses IS NULL)),
    CONSTRAINT check_max_uses CHECK (max_uses IS NULL OR max_uses > 0)
);

-- Create indexes
CREATE INDEX IF NOT EXISTS idx_registration_tokens_token ON registration_tokens(token);
CREATE INDEX IF NOT EXISTS idx_registration_tokens_expires_at ON registration_tokens(expires_at);
CREATE INDEX IF NOT EXISTS idx_registration_tokens_created_by ON registration_tokens(created_by);

-- Add comments
COMMENT ON TABLE registration_tokens IS 'Secure registration tokens for device authentication during registration';
COMMENT ON COLUMN registration_tokens.token IS 'Unique secure token (generated with secrets.token_urlsafe)';
COMMENT ON COLUMN registration_tokens.description IS 'Human-readable description of token purpose';
COMMENT ON COLUMN registration_tokens.max_uses IS 'Maximum number of times token can be used (NULL for unlimited)';
COMMENT ON COLUMN registration_tokens.current_uses IS 'Current number of times token has been used';
COMMENT ON COLUMN registration_tokens.expires_at IS 'Expiration timestamp (NULL for no expiration)';
"""


async def run_migration():
    """Run the registration_tokens table migration"""
    print("=" * 80)
    print("REGISTRATION TOKENS TABLE MIGRATION")
    print("=" * 80)
    print(f"\nDatabase: {DB_HOST}:{DB_PORT}/{DB_NAME}")
    print(f"User: {DB_USER}\n")

    try:
        # Connect to database
        print("Connecting to database...")
        conn = await asyncpg.connect(
            host=DB_HOST, port=DB_PORT, database=DB_NAME, user=DB_USER, password=DB_PASSWORD
        )
        print("✓ Connected\n")

        # Run migration
        print("Creating registration_tokens table...")
        await conn.execute(MIGRATION_SQL)
        print("✓ Table created\n")

        # Verify table exists
        print("Verifying table...")
        result = await conn.fetchval(
            """
            SELECT COUNT(*)
            FROM information_schema.tables
            WHERE table_name = 'registration_tokens'
            """
        )

        if result == 1:
            print("✓ Table verified\n")

            # Show table structure
            print("Table structure:")
            columns = await conn.fetch(
                """
                SELECT column_name, data_type, is_nullable
                FROM information_schema.columns
                WHERE table_name = 'registration_tokens'
                ORDER BY ordinal_position
                """
            )
            for col in columns:
                nullable = "NULL" if col["is_nullable"] == "YES" else "NOT NULL"
                print(f"  - {col['column_name']:20s} {col['data_type']:20s} {nullable}")

            print("\n" + "=" * 80)
            print("MIGRATION COMPLETED SUCCESSFULLY")
            print("=" * 80)
            return True
        else:
            print("✗ Table verification failed")
            return False

    except Exception as e:
        print(f"\n✗ Migration failed: {e}")
        import traceback

        traceback.print_exc()
        return False

    finally:
        if "conn" in locals():
            await conn.close()
            print("\n✓ Database connection closed")


if __name__ == "__main__":
    success = asyncio.run(run_migration())
    sys.exit(0 if success else 1)
