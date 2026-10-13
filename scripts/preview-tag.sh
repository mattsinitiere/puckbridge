#!/bin/bash
# The preview tag for a branch: "preview-" + the branch name with anything but letters, digits, . _ - turned into -.
printf 'preview-%s\n' "$(printf '%s' "${1:?branch}" | tr -c 'A-Za-z0-9._-' '-')"
