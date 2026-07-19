### Internal

- The live SASLprep/SCRAM PostgreSQL tests now skip when the suite role lacks the `CREATEROLE` privilege their throwaway login-role fixtures require, instead of failing with an opaque `ExecFailed` out of the setup DDL. Running the suite against a plain dev PostgreSQL whose suite role is not a superuser no longer reports two misleading SCRAM failures; CI (whose suite role is a superuser) still runs them. The module header documents both preconditions and how to point `ZIGBASE_PG_TEST_URL` at a privileged role to run them locally.
