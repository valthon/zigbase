Use the installed `$zigbase-app-genesis` skill to build a community gear-lending app. Anonymous visitors can browse available equipment. Authenticated members list equipment and request a date range; owners approve or reject requests.

Deliver a secure application with in-process authorization tests and a project-declared client or browser integration test for the critical browse/request journey. Keep any test-only plain-HTTP server profile separate from deployment.

Provide a production-shaped Docker Compose deployment that is reproducible and runnable locally: pin the application or ZigBase version, persist the complete data directory and JWT identity, leave secure cookies enabled behind an HTTPS termination boundary, configure mail delivery without committing credentials, and document health, doctor, backup, restore, upgrade, and rollback checks. Work entirely in the provided empty workspace.
