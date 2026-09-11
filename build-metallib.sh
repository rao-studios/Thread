#!/usr/bin/env bash
# WHAT: Build MLX's mlx.metallib into this package's .build.
# IN:   [debug|release] (default debug). FRIGATE_DIR overrides where Frigate lives.
# PIN:  A DELEGATE, NOT AN IMPLEMENTATION. Frigate owns the .metal sources, so it owns the
#       compile. Five hand-copied versions of this script had drifted apart, and this one
#       still pointed at .build/checkouts/mlx-swift — a path that stopped existing when
#       Frigate vendored mlx-swift, so it failed with "shaders not found" rather than
#       producing anything. The canonical script also installs into .xctest bundles, which
#       none of the copies did.
#
#   ./build-metallib.sh [debug|release]
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRIGATE_DIR="${FRIGATE_DIR:-$REPO_ROOT/../Frigate}"
CANONICAL="$FRIGATE_DIR/scripts/build-metallib.sh"

if [ ! -x "$CANONICAL" ]; then
    echo "build-metallib: cannot find $CANONICAL" >&2
    echo "  Set FRIGATE_DIR to your Frigate checkout." >&2
    exit 1
fi

exec "$CANONICAL" "${1:-debug}" --package "$REPO_ROOT"
