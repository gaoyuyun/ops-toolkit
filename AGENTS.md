# Repository Instructions

## Required checks for code changes

After every code change, run and require all of these checks to pass before
finishing:

```bash
shellcheck bootstrap.sh.in install.sh.in
find bin lib modules scripts tests tools -type f \( -name '*.sh' -o -path 'bin/opsctl' \) -print0 | xargs -0 shellcheck
shfmt -d -i 2 -ci bootstrap.sh.in install.sh.in bin lib modules scripts tests tools
tests/run.sh
```

If a required tool is unavailable, report the missing check explicitly.

## Release and tag checklist

Before creating or moving a `vX.Y.Z` tag:

1. Update `VERSION` to `X.Y.Z`.
2. Update the current version and release URLs in `README.md`.
3. Update version assertions and artifact paths in `tests/test_cli.sh` and `tests/test_release.sh`.
4. Search for both plain and regex-escaped references to the previous version:

   ```bash
   previous_version=0.1.0 # replace with the release being superseded
   rg -nF -e "$previous_version" -e "${previous_version//./\\.}" README.md VERSION tests
   ```

5. Run the same checks as CI and require all of them to pass:

   ```bash
   shellcheck bootstrap.sh.in install.sh.in
   find bin lib modules scripts tests tools -type f \( -name '*.sh' -o -path 'bin/opsctl' \) -print0 | xargs -0 shellcheck
   shfmt -d -i 2 -ci bootstrap.sh.in install.sh.in bin lib modules scripts tests tools
   tests/run.sh
   ```

6. Verify the tag/version match before pushing the tag:

   ```bash
   test "${TAG#v}" = "$(tr -d '[:space:]' < VERSION)"
   ```

Push the tag only after the target commit passes these checks. Do not force-move an existing remote tag without explicit user confirmation.
