#!/usr/bin/env bash
git ls-files . | grep -e '.*\.hs' | grep -v -e "test" | xargs hlint "$@"
