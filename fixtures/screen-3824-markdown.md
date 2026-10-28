# Markdown format check

## Next action

Run this to confirm the repo state:

```bash
git -C /Users/demo/sandbox/demo-repo status
```

## Checklist

- [x] Confirm the repo is a git repository
- [x] Confirm the tree is clean
- [ ] Run the tests
- [ ] Push the branch

## Status by check

| Check | Result | Next step |
|---|---|---|
| Git status | Clean on `main` | None |
| Python sample | Prints a greeting | Add a test |
| TypeScript sample | Typed helper | Compile it |

## Sample code

```python
def greet(name: str) -> str:
    return f"hello {name}"
```

```typescript
const greet = (name: string): string => `hello ${name}`;
```

> [!NOTE]
> This reply used no tools. It only shows the requested format.
