#!/usr/bin/env bash
# Stage setup.sh for deployment, refusing to publish a script that is broken
# or truncated -- whatever lands here gets piped straight into a root shell
# by the install line. These checks came from .github/workflows/publish-rx.yml,
# which this replaces.

set -euo pipefail

script=setup.sh

bash -n "$script"

head -1 "$script" | grep -qx '#!/usr/bin/env bash' \
  || { echo "missing or unexpected shebang" >&2; exit 1; }

# The body lives inside main(); without the trailing invocation the published
# file would parse cleanly and then do nothing at all.
tail -1 "$script" | grep -qx 'main "\$@"' \
  || { echo "script does not end with 'main \"\$@\"'" >&2; exit 1; }

rm -rf dist
mkdir -p dist
install -m 0644 "$script" dist/setup.sh

# Identifies the deployed commit so the fallback workflow can tell whether
# Cloudflare already published this tree.
printf '%s\n' "${WORKERS_CI_COMMIT_SHA:-${GITHUB_SHA:-local}}" > dist/.build-id

echo "verified and staged $(wc -l < "$script") lines"
