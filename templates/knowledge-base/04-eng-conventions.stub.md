<!-- intellisense: requires team input (0% extracted). Claude cannot infer this from code. -->
# Engineering Conventions

Team-defined conventions for this repo. Claude enforces these when writing or reviewing code.

## Naming Conventions

<!-- TODO: How are files, functions, variables, and types named in this repo? -->

Examples:
- Files: `[snake_case | kebab-case | PascalCase].go`
- Functions: `[camelCase | PascalCase]`
- Database columns: `[snake_case]`
- Constants: `[UPPER_SNAKE_CASE]`

## Error Handling Style

<!-- TODO: How are errors handled, wrapped, and logged? -->

Examples:
- All errors wrapped with context: `fmt.Errorf("UserService.GetByID: %w", err)`
- Never swallow errors — always return or log
- HTTP errors use custom `AppError` type with status code

## PR Checklist

<!-- TODO: What must be true before any PR is merged? -->

- [ ] Tests pass locally
- [ ] No new lint warnings
- [ ] [Add repo-specific items]

## Code Review Standards

<!-- TODO: What reviewers look for beyond automated checks -->

- Response time: within [N] hours
- Blocking comments must be resolved before merge
- [Add repo-specific standards]
