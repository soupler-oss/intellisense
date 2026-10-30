# Protected Files

Protected files require extra care, approval, or cannot be edited without special handling.

## Never Edit Without Approval

These files have production impact and must be reviewed carefully:

- Database migrations (changes are permanent)
- Configuration files (affects production behavior)
- Environment variable templates
- Secret credential files (never commit credentials)

## Protected Directories

| Directory | Policy |
|-----------|--------|
| `.git` | Review before editing |

## Generated or Compiled Files

Do not edit these files directly:

- Build output directories (dist/, build/)
- npm/composer/pip vendor files
- Compiled binaries
- Database migrations history

## Require Full Test Coverage Before Touching

Before modifying these, ensure:
- Unit tests pass
- Integration tests pass (if applicable)
- Database tests pass (if schema touched)
- Security review passed (if auth/payment touched)

Files in the risk-register.md "High-Risk Files" section always require this level of scrutiny.
