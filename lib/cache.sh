#!/usr/bin/env bash

create_signature() {
  echo "v2; ${STACK}; $(node --version); $(npm --version); $(yarn --version 2>/dev/null || true); ${PREBUILD}"
}

save_signature() {
  local cache_dir="$1"
  create_signature > "$cache_dir/node/signature"
}

load_signature() {
  local cache_dir="$1"
  if test -f "$cache_dir/node/signature"; then
    cat "$cache_dir/node/signature"
  else
    echo ""
  fi
}

get_cache_status() {
  local cache_dir="$1"
  echo "get_cache_status cache_dir $cache_dir"
  echo "cache_dir contents:"
  ls -la $cache_dir
  if ! ${NODE_MODULES_CACHE:-true}; then
    echo "disabled"
  elif ! test -d "$cache_dir/node/"; then
    echo "not-found"
  elif [ "$(create_signature)" != "$(load_signature "$cache_dir")" ]; then
    echo "new-signature"
  else
    echo "valid"
  fi
}

get_cache_directories() {
  local build_dir="$1"
  local dirs1 dirs2
  dirs1=$(read_json "$build_dir/package.json" ".cacheDirectories | .[]?")
  dirs2=$(read_json "$build_dir/package.json" ".cache_directories | .[]?")

  if [ -n "$dirs1" ]; then
    echo "$dirs1"
  else
    echo "$dirs2"
  fi
}

restore_default_cache_directories() {
  local build_dir=${1:-}
  local cache_dir=${2:-}
  local yarn_cache_dir=${3:-}
  local npm_cache=${4:-}
  local pnpm_cache_dir=${5:-}

  if [[ "$YARN" == "true" ]]; then
    if has_yarn_cache "$build_dir"; then
      echo "- yarn cache is checked into source control and cannot be cached"
    elif [[ -e "$cache_dir/node/cache/yarn" ]]; then
      rm -rf "$yarn_cache_dir"
      mv "$cache_dir/node/cache/yarn" "$yarn_cache_dir"
      if [[ -d "$yarn_cache_dir/yarn" ]]; then
        # Older versions of the buildpack may have created nested yarn caches.
        # This will remove the nested cache. This correction may be removed in
        # the near future.
        meta_set "yarn_nested_cache" "true"
        rm -rf "$yarn_cache_dir/yarn"
      fi
      echo "- yarn cache"
    else
      echo "- yarn cache (not cached - skipping)"
    fi
  elif [[ "$PNPM" == "true" ]]; then
    if [[ -d "$cache_dir/node/cache/pnpm" ]]; then
      rm -rf "$pnpm_cache_dir"
      mv "$cache_dir/node/cache/pnpm" "$pnpm_cache_dir"
      echo "- pnpm cache"
      meta_set "pnpm_cache" "true"
    else
      echo "- pnpm cache (not cached - skipping)"
    fi
  elif [[ "$USE_NPM_INSTALL" == "false" ]]; then
    if [[ -d "$cache_dir/node/cache/npm" ]]; then
      rm -rf "$npm_cache"
      mv "$cache_dir/node/cache/npm" "$npm_cache"
      echo "- npm cache"
      meta_set "npm_cache" "true"
    else
      echo "- npm cache (not cached - skipping)"
    fi
  else
    # node_modules
    if [[ -e "$build_dir/node_modules" ]]; then
      echo "- node_modules is checked into source control and cannot be cached"
    elif [[ -e "$cache_dir/node/cache/node_modules" ]]; then
      echo "- node_modules"
      mkdir -p "$(dirname "$build_dir/node_modules")"
      mv "$cache_dir/node/cache/node_modules" "$build_dir/node_modules"
    else
      echo "- node_modules (not cached - skipping)"
    fi
  fi

  # bower_components, should be silent if it is not in the cache
  if [[ -e "$cache_dir/node/cache/bower_components" ]]; then
    echo "- bower_components"
  fi
}

restore_custom_cache_directories() {
  local cache_directories
  local build_dir=${1:-}
  local cache_dir=${2:-}
  # Parse the input string with multiple lines: "a\nb\nc" into an array
  mapfile -t cache_directories <<< "$3"

  echo "Loading ${#cache_directories[@]} from cacheDirectories (package.json):"

  for cachepath in "${cache_directories[@]}"; do
    if [ -e "$build_dir/$cachepath" ]; then
      echo "- $cachepath (exists - skipping)"
    else
      if [ -e "$cache_dir/node/cache/$cachepath" ]; then
        echo "- $cachepath"
        mkdir -p "$(dirname "$build_dir/$cachepath")"
        mv "$cache_dir/node/cache/$cachepath" "$build_dir/$cachepath"
      else
        echo "- $cachepath (not cached - skipping)"
      fi
    fi
  done
}

clear_cache() {
  local cache_dir="$1"
  rm -rf "$cache_dir/node"
  mkdir -p "$cache_dir/node"
  mkdir -p "$cache_dir/node/cache"
}

save_default_cache_directories() {
  local build_dir=${1:-}
  local cache_dir=${2:-}
  local yarn_cache_dir=${3:-}
  local npm_cache=${4:-}
  local pnpm_cache_dir=${5:-}

  if [[ "$YARN" == "true" ]]; then
    if [[ -d "$yarn_cache_dir" ]]; then
      if [[ "$YARN_2" == "true" ]] && ! node_modules_enabled "$BUILD_DIR"; then
        cp -RTf "$yarn_cache_dir" "$cache_dir/node/cache/yarn"
      else
        mv "$yarn_cache_dir" "$cache_dir/node/cache/yarn"
      fi
      echo "- yarn cache"
    fi
  elif [[ "$PNPM" == "true" ]]; then
    if [[ -d "$pnpm_cache_dir" ]]; then
      mv "$pnpm_cache_dir" "$cache_dir/node/cache/pnpm"
      echo "- pnpm cache"
    fi
  elif [[ "$USE_NPM_INSTALL" == "false" ]]; then
    if [[ -d "$npm_cache" ]]; then
      mv "$npm_cache" "$cache_dir/node/cache/npm"
      echo "- npm cache"
    else
      echo "- npm cache (nothing to cache)"
    fi
  else
    # node_modules
    if [[ -e "$build_dir/node_modules" ]]; then
      echo "- node_modules"
      mkdir -p "$cache_dir/node/cache/node_modules"
      cp -a "$build_dir/node_modules" "$(dirname "$cache_dir/node/cache/node_modules")"
    else
      # this can happen if there are no dependencies
      mcount "cache.no-node-modules"
      echo "- node_modules (nothing to cache)"
    fi
  fi

  # bower_components
  if [[ -e "$build_dir/bower_components" ]]; then
    mcount "cache.saved-bower-components"
    meta_set "cached-bower-components" "true"
    echo "- bower_components"
    mkdir -p "$cache_dir/node/cache/bower_components"
    cp -a "$build_dir/bower_components" "$(dirname "$cache_dir/node/cache/bower_components")"
  fi

  meta_set "node-custom-cache-dirs" "false"
}

save_custom_cache_directories() {
  local cache_directories
  local build_dir=${1:-}
  local cache_dir=${2:-}
  # Parse the input string with multiple lines: "a\nb\nc" into an array
  mapfile -t cache_directories <<< "$3"

  echo "Saving ${#cache_directories[@]} cacheDirectories (package.json):"

  for cachepath in "${cache_directories[@]}"; do
    if [ -e "$build_dir/$cachepath" ]; then
      echo "- $cachepath"
      mkdir -p "$cache_dir/node/cache/$cachepath"
      cp -a "$build_dir/$cachepath" "$(dirname "$cache_dir/node/cache/$cachepath")"
    else
      echo "- $cachepath (nothing to cache)"
    fi
  done

  meta_set "node-custom-cache-dirs" "true"
}

DEFAULT_PNPM_PRUNE_COUNTER_VALUE="40"

load_pnpm_prune_store_counter() {
  local cache_dir=${1:-}

  if [ -f "$cache_dir/pnpm_prune_store_counter" ]; then
    counter=$(<"$cache_dir/pnpm_prune_store_counter")
    if ! is_int "$counter" || (( counter < 0 )); then
      counter="$DEFAULT_PNPM_PRUNE_COUNTER_VALUE"
    fi
  else
    counter="$DEFAULT_PNPM_PRUNE_COUNTER_VALUE"
  fi

  echo "$counter"
}

save_pnpm_prune_store_counter() {
  local cache_dir=${1:-}
  local new_value=${2:-}

  if ! is_int "$new_value" || (( new_value < 0 )); then
    new_value="$DEFAULT_PNPM_PRUNE_COUNTER_VALUE"
  fi

  echo "$new_value" > "$cache_dir/pnpm_prune_store_counter"
}

is_int() {
  case ${1#[-+]} in
    '' | *[!0-9]*) return 1;;
  esac
}
