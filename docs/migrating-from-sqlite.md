# Migrating from the SQLite edition

Current Wolf Leader releases use PostgreSQL with pgvector. If your existing hub stores its data in
`data/ide-work.db`, migrate it before connecting updated clients.

## Before you start

Make a backup of the existing Wolf Leader folder. The migration also preserves that folder and the
SQLite database so you can return to it later.

The hub computer needs Docker Compose, Git or curl, and enough free space to keep both copies during
the migration.

## Use the desktop app

During setup, tell the Wolf Leader app where the existing hub runs. It can perform the upgrade on
the same Mac or over SSH to the hub computer. The app shows the old and new locations before it
changes anything.

## Run the migration by hand

From a current Wolf Leader checkout on the computer that runs the hub:

```bash
bash scripts/wolf-og-migrate.sh --upgrade
```

The script asks for the old hub folder, public hub address and share folder. It then:

1. leaves the original folder unchanged;
2. creates the PostgreSQL installation in a separate folder;
3. stops and preserves the old container;
4. copies projects, chats, messages and memories into PostgreSQL; and
5. verifies that the new hub answers its health check.

After the migration, open Wolf Leader and confirm that your projects and recent chats appear before
updating other computers.

## Roll back

Use **Settings → Hub → Downgrade** in the Mac app, or run:

```bash
bash scripts/wolf-og-migrate.sh --revert
```

The script can copy supported changes from PostgreSQL back into a backup copy of the SQLite
database before it restarts the original hub. Keep both hub folders until you are satisfied with
the migration.
