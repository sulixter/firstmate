#!/usr/bin/env bash
# Shared PR/MR record reads, validation, and atomic artifact helpers for merge
# polling on the supported forges. Callers must validate task IDs and raw PR/MR
# URLs before constructing task paths or performing any side effect.
#
# The stored identity is provider-tagged: provider, url, host, path, number.
# "path" is the full project path, which is owner/repository on GitHub and
# Gitea, an arbitrarily nested group/subgroup/project namespace on GitLab, and
# an arbitrarily nested project name on Gerrit, where "number" is the change
# number. On Gitea "host" is the whole origin, scheme and any port included
# (fm_pr_url_parse owns why). A GitLab or Gerrit project can sit at any depth, so no
# owner/repository pair can address one and the sidecar carries the whole path
# instead. Both also run on self-hosted instances, and Gerrit runs nowhere else,
# so the host is part of that identity rather than a constant. Every consumer re-derives the identity
# from the stored URL and refuses any record whose parts do not reconstruct that
# exact URL.
#
# A validated exact merged result is retired through a private receipt only
# after its durable wake is appended.
# The receipt binds the terminal observation to the canonical registration and
# lets a restart finish fixed-path removal without executing state-file bytes.

FM_PR_PROVIDER=
FM_PR_URL=
FM_PR_HOST=
FM_PR_PATH=
FM_PR_OWNER=
FM_PR_REPO=
FM_PR_NUMBER=
FM_PR_DATA_PROVIDER=
FM_PR_DATA_URL=
FM_PR_DATA_HOST=
FM_PR_DATA_PATH=
FM_PR_DATA_NUMBER=
FM_PR_META_PROVIDER=
FM_PR_META_URL=
FM_PR_META_HOST=
FM_PR_META_PATH=
FM_PR_META_NUMBER=
FM_PR_REG_ID=
FM_PR_REG_PROVIDER=
FM_PR_REG_URL=
FM_PR_REG_HOST=
FM_PR_REG_PATH=
FM_PR_REG_NUMBER=
FM_PR_REG_DATA_HASH=
FM_PR_REG_TEMPLATE_HASH=
FM_PR_REG_DATA_IDENTITY=
FM_PR_REG_CHECK_IDENTITY=
FM_PR_POLL_DATA_TMP=
FM_PR_POLL_CHECK_TMP=
FM_PR_POLL_REG_TMP=
FM_PR_POLL_DATA_DEST=
FM_PR_POLL_CHECK_DEST=
FM_PR_POLL_REG_DEST=
FM_PR_POLL_EXPECT_ID=
FM_PR_POLL_EXPECT_PROVIDER=
FM_PR_POLL_EXPECT_URL=
FM_PR_POLL_EXPECT_HOST=
FM_PR_POLL_EXPECT_PATH=
FM_PR_POLL_EXPECT_NUMBER=
FM_PR_POLL_EXPECT_DATA_HASH=
FM_PR_POLL_EXPECT_TEMPLATE_HASH=
FM_PR_POLL_EXPECT_DATA_IDENTITY=
FM_PR_POLL_EXPECT_CHECK_IDENTITY=
FM_PR_POLL_TEMPLATE=
FM_PR_POLL_STATE_DEVICE=
FM_PR_POLL_SNAPSHOT_ID=
FM_PR_POLL_SNAPSHOT_PROVIDER=
FM_PR_POLL_SNAPSHOT_URL=
FM_PR_POLL_SNAPSHOT_HOST=
FM_PR_POLL_SNAPSHOT_PATH=
FM_PR_POLL_SNAPSHOT_NUMBER=
FM_PR_POLL_SNAPSHOT_DATA_HASH=
FM_PR_POLL_SNAPSHOT_TEMPLATE_HASH=
FM_PR_POLL_SNAPSHOT_DATA_IDENTITY=
FM_PR_POLL_SNAPSHOT_CHECK_IDENTITY=
FM_PR_POLL_SNAPSHOT_REG_HASH=
FM_PR_POLL_SNAPSHOT_REG_IDENTITY=
FM_PR_POLL_REARM_DATA_IDENTITY=
FM_PR_POLL_REARM_CHECK_IDENTITY=
FM_PR_RETIRE_ID=
FM_PR_RETIRE_PROVIDER=
FM_PR_RETIRE_URL=
FM_PR_RETIRE_HOST=
FM_PR_RETIRE_PATH=
FM_PR_RETIRE_NUMBER=
FM_PR_RETIRE_DATA_HASH=
FM_PR_RETIRE_TEMPLATE_HASH=
FM_PR_RETIRE_DATA_IDENTITY=
FM_PR_RETIRE_CHECK_IDENTITY=
FM_PR_RETIRE_REG_HASH=
FM_PR_RETIRE_REG_IDENTITY=
FM_PR_RETIRE_RECEIPT_HASH=
FM_PR_RETIRE_RECEIPT_IDENTITY=
FM_PR_RECORD_STATE=
FM_PR_RECORD_MERGED=
FM_PR_POLL_RETIREMENT_REJECTED=

fm_task_id_path_safe() {
  local id=${1-}
  local LC_ALL=C
  case "$id" in
    ''|.*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
}

fm_pr_task_id_valid() {
  local id=${1-}
  fm_task_id_path_safe "$id"
}

fm_task_id_creation_valid() {
  local id=${1-}
  fm_pr_task_id_valid "$id" || return 1
  [ "${#id}" -le 64 ]
}

# GitLab and Gerrit both serve self-hosted instances, so the host is part of the
# identity rather than a constant. It is accepted only as a lowercase DNS name
# with no userinfo, port, or trailing dot, which keeps one canonical spelling per
# change. github.com is refused here even though its shape is otherwise valid:
# it is GitHub's own host and never another forge's instance, so a URL like
# https://github.com/o/r/-/merge_requests/1 (a typo'd or spoofed GitHub URL)
# would otherwise be armed as a watch that can never succeed.
fm_pr_forge_host_valid() {
  local host=${1-} label
  local LC_ALL=C
  local -a labels
  [ "${#host}" -ge 1 ] && [ "${#host}" -le 253 ] || return 1
  [ "$host" != github.com ] || return 1
  case "$host" in
    .*|*.|*..*|*[!a-z0-9.-]*) return 1 ;;
  esac
  IFS=. read -ra labels <<< "$host"
  for label in "${labels[@]}"; do
    [ "${#label}" -ge 1 ] && [ "${#label}" -le 63 ] || return 1
    case "$label" in
      -*|*-) return 1 ;;
    esac
  done
}

# A GitLab project path is group[/subgroup...]/project, so at least two
# segments and no fixed depth. GitLab reserves "-" as its route separator and
# forbids a leading hyphen, ".git", and ".atom", so none of those can name a
# real namespace and each is refused here.
fm_pr_gitlab_path_valid() {
  local path=${1-} segment
  local LC_ALL=C
  local -a segments
  [ "${#path}" -ge 3 ] && [ "${#path}" -le 1024 ] || return 1
  case "$path" in
    /*|*/|*//*) return 1 ;;
  esac
  IFS=/ read -ra segments <<< "$path"
  [ "${#segments[@]}" -ge 2 ] && [ "${#segments[@]}" -le 20 ] || return 1
  for segment in "${segments[@]}"; do
    [ "${#segment}" -ge 1 ] && [ "${#segment}" -le 255 ] || return 1
    case "$segment" in
      .|..|-*|*.git|*.atom|*[!A-Za-z0-9._-]*) return 1 ;;
    esac
  done
}

# A Gerrit project name is itself a path at no fixed depth, and it needs no
# enclosing group, so a single segment is canonical here where GitLab needs at
# least two. Gerrit reserves no route segment inside the name, so nothing
# corresponds to GitLab's "-": the change URL's literal "/+/" is what ends the
# project instead. A ".git" suffix is refused because Gerrit strips it and the
# stripped name is the canonical one, and a leading hyphen is refused because a
# project path is what names the project to any CLI that takes one, where a
# leading hyphen reads as an option instead.
fm_pr_gerrit_path_valid() {
  local path=${1-} segment
  local LC_ALL=C
  local -a segments
  [ "${#path}" -ge 1 ] && [ "${#path}" -le 1024 ] || return 1
  case "$path" in
    /*|*/|*//*) return 1 ;;
  esac
  IFS=/ read -ra segments <<< "$path"
  [ "${#segments[@]}" -ge 1 ] && [ "${#segments[@]}" -le 20 ] || return 1
  for segment in "${segments[@]}"; do
    [ "${#segment}" -ge 1 ] && [ "${#segment}" -le 255 ] || return 1
    case "$segment" in
      .|..|-*|*.git|*[!A-Za-z0-9._-]*) return 1 ;;
    esac
  done
}

# A Gitea owner is a user or organization name: letters, digits, ".", "_", and
# "-", starting and ending with a letter or digit, with no two of those
# separators adjacent. A repository name may use the same characters, but a
# leading hyphen is refused because it would read as an option to any CLI that
# takes the name, and ".git" and ".wiki" suffixes are refused because Gitea
# strips the first and serves the second as the wiki rather than the
# repository, so neither is a canonical repository spelling.
fm_pr_gitea_path_valid() {
  local path=${1-} owner repo
  local LC_ALL=C
  case "$path" in
    */*/*|/*|*/) return 1 ;;
    */*) ;;
    *) return 1 ;;
  esac
  owner=${path%%/*}
  repo=${path#*/}
  [ "${#owner}" -ge 1 ] && [ "${#owner}" -le 40 ] || return 1
  case "$owner" in
    [!A-Za-z0-9]*|*[!A-Za-z0-9]|*[!A-Za-z0-9._-]*|*[._-][._-]*) return 1 ;;
  esac
  [ "${#repo}" -ge 1 ] && [ "${#repo}" -le 100 ] || return 1
  case "$repo" in
    .|..|-*|*.git|*.wiki|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
}

# Parse a canonical pull request, merge request, or Gerrit change URL into the
# provider-tagged identity. Validation is strict and per provider: the GitHub
# username and repository rules are unchanged, and GitLab, Gerrit, and Gitea
# each get their own namespace rules rather than a loosened GitHub rule.
#
# FM_PR_OWNER and FM_PR_REPO are additionally set for github because
# bin/fm-pr-merge.sh addresses GitHub by owner/repository. A gitlab or gerrit
# URL leaves them empty, and those paths address the project by FM_PR_HOST and
# FM_PR_PATH instead, so a change on any instance resolves without a hardcoded
# host.
#
# A Gitea pull request URL is <scheme>://<host>[:<port>]/<owner>/<repo>/pulls/<n>.
# Gitea is commonly self-hosted on a private network behind plain http and a
# non-default port, so this provider alone accepts http and a port; the GitHub,
# GitLab, and Gerrit patterns are unchanged and still require https with no
# port. Because the scheme and port then name a different server, FM_PR_HOST
# for gitea is the whole origin, <scheme>://<host>[:<port>], rather than a bare
# host, so the stored identity can never conflate two servers. A default port
# spelled out (:80 on http, :443 on https) is refused as a non-canonical second
# spelling of the same pull request. Accepting the URL is not trust in the
# server: every Gitea read and merge goes only through a tea login whose
# configured URL is exactly that origin (fm_pr_gitea_login), so a URL naming
# any other server reaches nothing.
fm_pr_url_parse() {
  local raw=${1-} pattern host path
  local LC_ALL=C
  FM_PR_PROVIDER=
  FM_PR_URL=
  FM_PR_HOST=
  FM_PR_PATH=
  FM_PR_OWNER=
  FM_PR_REPO=
  FM_PR_NUMBER=
  pattern='^https://github\.com/([A-Za-z0-9]|[A-Za-z0-9][A-Za-z0-9-]{0,37}[A-Za-z0-9])/([A-Za-z0-9._-]{1,100})/pull/([1-9][0-9]*)$'
  if [[ "$raw" =~ $pattern ]]; then
    [[ "${BASH_REMATCH[1]}" != *--* ]] || return 1
    [ "${BASH_REMATCH[2]}" != . ] && [ "${BASH_REMATCH[2]}" != .. ] || return 1
    FM_PR_PROVIDER=github
    FM_PR_URL=$raw
    FM_PR_HOST=github.com
    FM_PR_PATH="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
    # Consumed by bin/fm-pr-merge.sh, which addresses GitHub by owner/repository.
    # shellcheck disable=SC2034
    FM_PR_OWNER=${BASH_REMATCH[1]}
    # shellcheck disable=SC2034
    FM_PR_REPO=${BASH_REMATCH[2]}
    FM_PR_NUMBER=${BASH_REMATCH[3]}
    return 0
  fi
  # The path class contains "/" and "-", so this match is greedy to the last
  # "/-/merge_requests/". Any earlier separator therefore lands inside the
  # captured path, where the reserved "-" segment is refused.
  pattern='^https://([a-z0-9.-]{1,253})/([A-Za-z0-9._/-]+)/-/merge_requests/([1-9][0-9]*)$'
  if [[ "$raw" =~ $pattern ]]; then
    host=${BASH_REMATCH[1]}
    path=${BASH_REMATCH[2]}
    fm_pr_forge_host_valid "$host" || return 1
    fm_pr_gitlab_path_valid "$path" || return 1
    FM_PR_PROVIDER=gitlab
    FM_PR_URL=$raw
    FM_PR_HOST=$host
    FM_PR_PATH=$path
    FM_PR_NUMBER=${BASH_REMATCH[3]}
    return 0
  fi
  # The owner and repository classes exclude "/", so this pattern names exactly
  # two path segments and cannot overlap the GitLab or Gerrit forms, whose
  # route separators sit at other depths.
  pattern='^(https?)://([a-z0-9.-]{1,253})(:([1-9][0-9]{0,4}))?/([A-Za-z0-9._-]{1,40})/([A-Za-z0-9._-]{1,100})/pulls/([1-9][0-9]*)$'
  if [[ "$raw" =~ $pattern ]]; then
    local scheme=${BASH_REMATCH[1]} port=${BASH_REMATCH[4]} owner=${BASH_REMATCH[5]} repo=${BASH_REMATCH[6]} number=${BASH_REMATCH[7]}
    host=${BASH_REMATCH[2]}
    fm_pr_forge_host_valid "$host" || return 1
    if [ -n "$port" ]; then
      [ "$port" -le 65535 ] || return 1
      [ "$scheme:$port" != http:80 ] && [ "$scheme:$port" != https:443 ] || return 1
    fi
    fm_pr_gitea_path_valid "$owner/$repo" || return 1
    FM_PR_PROVIDER=gitea
    FM_PR_URL=$raw
    FM_PR_HOST="$scheme://$host${port:+:$port}"
    FM_PR_PATH="$owner/$repo"
    # shellcheck disable=SC2034
    FM_PR_OWNER=$owner
    # shellcheck disable=SC2034
    FM_PR_REPO=$repo
    FM_PR_NUMBER=$number
    return 0
  fi
  # A Gerrit change URL is https://<host>/c/<project>/+/<number>. "+" is outside
  # the path class, so the project can never contain the "/+/" separator and this
  # match needs no greediness argument: a second "/+/" makes the URL match
  # nothing rather than splitting somewhere else. The project keeps its whole
  # nested path for the same reason GitLab's does, so it is never flattened into
  # an owner/repository pair that cannot address it.
  pattern='^https://([a-z0-9.-]{1,253})/c/([A-Za-z0-9._/-]+)/\+/([1-9][0-9]*)$'
  [[ "$raw" =~ $pattern ]] || return 1
  host=${BASH_REMATCH[1]}
  path=${BASH_REMATCH[2]}
  fm_pr_forge_host_valid "$host" || return 1
  fm_pr_gerrit_path_valid "$path" || return 1
  FM_PR_PROVIDER=gerrit
  FM_PR_URL=$raw
  FM_PR_HOST=$host
  FM_PR_PATH=$path
  FM_PR_NUMBER=${BASH_REMATCH[3]}
}

fm_pr_head_valid() {
  local head=${1-}
  local LC_ALL=C
  [[ "$head" =~ ^[0-9a-f]{40}$|^[0-9a-f]{64}$ ]]
}

# The one reading of a GitHub pull request's draft state. Prints "true" or
# "false" for a boolean isDraft and nothing for anything else, so a caller can
# tell a positive draft from an unreadable payload. bin/fm-pr-merge.sh refuses
# a merge unless this prints "false"; bin/fm-pr-check.sh refuses to arm a merge
# poll only when it prints "true".
fm_pr_json_draft_state() {  # <pull-request-json>
  printf '%s' "${1-}" | jq -r '
    if type == "object" and (.isDraft | type) == "boolean" then (.isDraft | tostring) else "" end
  ' 2>/dev/null || true
}

fm_pr_file_mode() {
  if [ "$(uname)" = Darwin ]; then
    /usr/bin/stat -f %Lp "$1" 2>/dev/null
  else
    stat -c %a "$1" 2>/dev/null
  fi
}

fm_pr_file_device() {
  if [ "$(uname)" = Darwin ]; then
    /usr/bin/stat -f %d "$1" 2>/dev/null
  else
    stat -c %d "$1" 2>/dev/null
  fi
}

fm_pr_file_link_count() {
  if [ "$(uname)" = Darwin ]; then
    /usr/bin/stat -f %l "$1" 2>/dev/null
  else
    stat -c %h "$1" 2>/dev/null
  fi
}

fm_pr_file_inode() {
  if [ "$(uname)" = Darwin ]; then
    /usr/bin/stat -f %i "$1" 2>/dev/null
  else
    stat -c %i "$1" 2>/dev/null
  fi
}

# device:inode names one file object, since an inode number is unique only
# within its filesystem. The device part is not stable across a volume remount:
# APFS can renumber st_dev on reboot while every inode and byte is unchanged, so
# an identity persisted before the remount no longer matches the live file
# (fm_pr_poll_registration_rerecord_device).
fm_pr_file_identity() {
  local device inode
  device=$(fm_pr_file_device "$1") || return 1
  inode=$(fm_pr_file_inode "$1") || return 1
  [ -n "$device" ] && [ -n "$inode" ] || return 1
  printf '%s:%s\n' "$device" "$inode"
}

fm_pr_sha256() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" 2>/dev/null | awk '{print $1}'
  else
    return 1
  fi
}

# Callers pass the containing directory's device read in the same invocation,
# never a persisted one, so this compares two live readings and survives a
# remount that renumbers the volume. It refuses a file that is not on that
# directory's own filesystem, such as one bind-mounted over the name, which is
# also what keeps same-directory rename publication atomic.
fm_pr_private_file_valid() {
  local path=$1 mode=$2 device=$3
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  [ "$(fm_pr_file_mode "$path")" = "$mode" ] || return 1
  [ "$(fm_pr_file_device "$path")" = "$device" ] || return 1
  [ "$(fm_pr_file_link_count "$path")" = 1 ]
}

fm_pr_regular_destination_or_absent() {
  local path=$1
  [ ! -L "$path" ] || return 1
  if [ -e "$path" ]; then
    [ -f "$path" ] && [ "$(fm_pr_file_link_count "$path")" = 1 ]
  fi
}

fm_pr_regular_destination_on_device_or_absent() {
  local path=$1 device=$2
  fm_pr_regular_destination_or_absent "$path" || return 1
  [ ! -e "$path" ] || [ "$(fm_pr_file_device "$path")" = "$device" ]
}

fm_pr_metadata_identity_parse() {
  local file=$1 line value pr_count=0 seen_pr=0 post_pr_invalid=0
  FM_PR_META_PROVIDER=
  FM_PR_META_URL=
  FM_PR_META_HOST=
  FM_PR_META_PATH=
  FM_PR_META_NUMBER=
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  [ "$(fm_pr_file_link_count "$file")" = 1 ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      pr=*)
        pr_count=$((pr_count + 1))
        [ "$pr_count" -eq 1 ] || continue
        value=${line#pr=}
        if fm_pr_url_parse "$value"; then
          FM_PR_META_PROVIDER=$FM_PR_PROVIDER
          FM_PR_META_URL=$FM_PR_URL
          FM_PR_META_HOST=$FM_PR_HOST
          FM_PR_META_PATH=$FM_PR_PATH
          FM_PR_META_NUMBER=$FM_PR_NUMBER
        fi
        seen_pr=1
        ;;
      pr_head=*)
        if [ "$seen_pr" -eq 1 ]; then
          value=${line#pr_head=}
          fm_pr_head_valid "$value" || post_pr_invalid=1
        fi
        ;;
      x_request=*|x_request_ts=*|x_followups=*|x_platform=*|x_reply_max_chars=*)
        ;;
      *)
        [ "$seen_pr" -eq 0 ] || post_pr_invalid=1
        ;;
    esac
  done < "$file"
  [ "$pr_count" -eq 1 ] || return 1
  [ "$post_pr_invalid" -eq 0 ] || return 1
  [ -n "$FM_PR_META_URL" ]
}

# Sidecar layout: provider, url, host, path, number, one per line. A sidecar
# written before the provider tag existed has a URL on its first line and one
# line fewer, so it fails both the field count and the provider comparison and
# is refused rather than misread as a provider-tagged record.
fm_pr_poll_data_parse() {
  local file=$1 provider url host path number
  FM_PR_DATA_PROVIDER=
  FM_PR_DATA_URL=
  FM_PR_DATA_HOST=
  FM_PR_DATA_PATH=
  FM_PR_DATA_NUMBER=
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  exec 8< "$file" || return 1
  IFS= read -r provider <&8 || { exec 8<&-; return 1; }
  IFS= read -r url <&8 || { exec 8<&-; return 1; }
  IFS= read -r host <&8 || { exec 8<&-; return 1; }
  IFS= read -r path <&8 || { exec 8<&-; return 1; }
  IFS= read -r number <&8 || { exec 8<&-; return 1; }
  if IFS= read -r _extra <&8; then
    exec 8<&-
    return 1
  fi
  exec 8<&-
  fm_pr_url_parse "$url" || return 1
  [ "$provider" = "$FM_PR_PROVIDER" ] || return 1
  [ "$host" = "$FM_PR_HOST" ] || return 1
  [ "$path" = "$FM_PR_PATH" ] || return 1
  [ "$number" = "$FM_PR_NUMBER" ] || return 1
  FM_PR_DATA_PROVIDER=$FM_PR_PROVIDER
  FM_PR_DATA_URL=$FM_PR_URL
  FM_PR_DATA_HOST=$FM_PR_HOST
  FM_PR_DATA_PATH=$FM_PR_PATH
  FM_PR_DATA_NUMBER=$FM_PR_NUMBER
}

# Registration layout: version tag, task id, then the same provider-tagged
# identity as the sidecar, then the two hashes and the two file identities.
# The version tag moved to v2 with the provider tag, so a registration written
# by the previous release is recognised as old and refused.
fm_pr_poll_registration_parse() {
  local file=$1 version id provider url host path number data_hash template_hash data_identity check_identity
  FM_PR_REG_ID=
  FM_PR_REG_PROVIDER=
  FM_PR_REG_URL=
  FM_PR_REG_HOST=
  FM_PR_REG_PATH=
  FM_PR_REG_NUMBER=
  FM_PR_REG_DATA_HASH=
  FM_PR_REG_TEMPLATE_HASH=
  FM_PR_REG_DATA_IDENTITY=
  FM_PR_REG_CHECK_IDENTITY=
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  exec 7< "$file" || return 1
  IFS= read -r version <&7 || { exec 7<&-; return 1; }
  IFS= read -r id <&7 || { exec 7<&-; return 1; }
  IFS= read -r provider <&7 || { exec 7<&-; return 1; }
  IFS= read -r url <&7 || { exec 7<&-; return 1; }
  IFS= read -r host <&7 || { exec 7<&-; return 1; }
  IFS= read -r path <&7 || { exec 7<&-; return 1; }
  IFS= read -r number <&7 || { exec 7<&-; return 1; }
  IFS= read -r data_hash <&7 || { exec 7<&-; return 1; }
  IFS= read -r template_hash <&7 || { exec 7<&-; return 1; }
  IFS= read -r data_identity <&7 || { exec 7<&-; return 1; }
  IFS= read -r check_identity <&7 || { exec 7<&-; return 1; }
  if IFS= read -r _extra <&7; then
    exec 7<&-
    return 1
  fi
  exec 7<&-
  [ "$version" = fm-pr-poll-registration-v2 ] || return 1
  fm_pr_task_id_valid "$id" || return 1
  fm_pr_url_parse "$url" || return 1
  [ "$provider" = "$FM_PR_PROVIDER" ] || return 1
  [ "$host" = "$FM_PR_HOST" ] || return 1
  [ "$path" = "$FM_PR_PATH" ] || return 1
  [ "$number" = "$FM_PR_NUMBER" ] || return 1
  [[ "$data_hash" =~ ^[0-9a-f]{64}$ ]] || return 1
  [[ "$template_hash" =~ ^[0-9a-f]{64}$ ]] || return 1
  [[ "$data_identity" =~ ^[0-9]+:[0-9]+$ ]] || return 1
  [[ "$check_identity" =~ ^[0-9]+:[0-9]+$ ]] || return 1
  FM_PR_REG_ID=$id
  FM_PR_REG_PROVIDER=$FM_PR_PROVIDER
  FM_PR_REG_URL=$FM_PR_URL
  FM_PR_REG_HOST=$FM_PR_HOST
  FM_PR_REG_PATH=$FM_PR_PATH
  FM_PR_REG_NUMBER=$FM_PR_NUMBER
  FM_PR_REG_DATA_HASH=$data_hash
  FM_PR_REG_TEMPLATE_HASH=$template_hash
  FM_PR_REG_DATA_IDENTITY=$data_identity
  FM_PR_REG_CHECK_IDENTITY=$check_identity
}

fm_pr_poll_cleanup() {
  [ -z "$FM_PR_POLL_DATA_TMP" ] || rm -f -- "$FM_PR_POLL_DATA_TMP"
  [ -z "$FM_PR_POLL_CHECK_TMP" ] || rm -f -- "$FM_PR_POLL_CHECK_TMP"
  [ -z "$FM_PR_POLL_REG_TMP" ] || rm -f -- "$FM_PR_POLL_REG_TMP"
  FM_PR_POLL_DATA_TMP=
  FM_PR_POLL_CHECK_TMP=
  FM_PR_POLL_REG_TMP=
}

fm_pr_poll_revoke_final() {
  local failed=0
  # Neutralize the runnable name first so a failed rearm cannot consume state
  # whose transactional registration did not commit successfully.
  if [ -e "$FM_PR_POLL_CHECK_DEST" ] || [ -L "$FM_PR_POLL_CHECK_DEST" ]; then
    rm -f -- "$FM_PR_POLL_CHECK_DEST" || failed=1
  fi
  if [ -e "$FM_PR_POLL_REG_DEST" ] || [ -L "$FM_PR_POLL_REG_DEST" ]; then
    rm -f -- "$FM_PR_POLL_REG_DEST" || failed=1
  fi
  if [ -e "$FM_PR_POLL_DATA_DEST" ] || [ -L "$FM_PR_POLL_DATA_DEST" ]; then
    rm -f -- "$FM_PR_POLL_DATA_DEST" || failed=1
  fi
  [ ! -e "$FM_PR_POLL_CHECK_DEST" ] && [ ! -L "$FM_PR_POLL_CHECK_DEST" ] || failed=1
  [ ! -e "$FM_PR_POLL_REG_DEST" ] && [ ! -L "$FM_PR_POLL_REG_DEST" ] || failed=1
  [ ! -e "$FM_PR_POLL_DATA_DEST" ] && [ ! -L "$FM_PR_POLL_DATA_DEST" ] || failed=1
  return "$failed"
}

fm_pr_poll_prepare() {
  local state=$1 id=$2 provider=$3 url=$4 host=$5 path=$6 number=$7 template=$8
  fm_pr_task_id_valid "$id" || return 1
  fm_pr_url_parse "$url" || return 1
  [ "$provider" = "$FM_PR_PROVIDER" ] || return 1
  [ "$host" = "$FM_PR_HOST" ] || return 1
  [ "$path" = "$FM_PR_PATH" ] || return 1
  [ "$number" = "$FM_PR_NUMBER" ] || return 1
  [ -f "$template" ] || return 1

  [ ! -L "$state" ] || return 1
  mkdir -p "$state" || return 1
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  umask 077
  FM_PR_POLL_DATA_DEST="$state/$id.pr-poll"
  FM_PR_POLL_CHECK_DEST="$state/$id.check.sh"
  FM_PR_POLL_REG_DEST="$state/$id.pr-poll-registration"
  FM_PR_POLL_EXPECT_ID=$id
  FM_PR_POLL_EXPECT_PROVIDER=$provider
  FM_PR_POLL_EXPECT_URL=$url
  FM_PR_POLL_EXPECT_HOST=$host
  FM_PR_POLL_EXPECT_PATH=$path
  FM_PR_POLL_EXPECT_NUMBER=$number
  FM_PR_POLL_TEMPLATE=$template
  FM_PR_POLL_STATE_DEVICE=$(fm_pr_file_device "$state") || return 1
  [ -n "$FM_PR_POLL_STATE_DEVICE" ] || return 1
  FM_PR_POLL_DATA_TMP=$(mktemp "$state/.fm-pr-poll-data.XXXXXX") || return 1
  FM_PR_POLL_CHECK_TMP=$(mktemp "$state/.fm-pr-poll-check.XXXXXX") || {
    fm_pr_poll_cleanup
    return 1
  }
  FM_PR_POLL_REG_TMP=$(mktemp "$state/.fm-pr-poll-registration.XXXXXX") || {
    fm_pr_poll_cleanup
    return 1
  }

  if ! printf '%s\n%s\n%s\n%s\n%s\n' "$provider" "$url" "$host" "$path" "$number" > "$FM_PR_POLL_DATA_TMP" \
    || ! chmod 0600 "$FM_PR_POLL_DATA_TMP" \
    || ! fm_pr_private_file_valid "$FM_PR_POLL_DATA_TMP" 600 "$FM_PR_POLL_STATE_DEVICE" \
    || ! fm_pr_poll_data_parse "$FM_PR_POLL_DATA_TMP" \
    || [ "$FM_PR_DATA_PROVIDER" != "$provider" ] \
    || [ "$FM_PR_DATA_URL" != "$url" ] \
    || [ "$FM_PR_DATA_HOST" != "$host" ] \
    || [ "$FM_PR_DATA_PATH" != "$path" ] \
    || [ "$FM_PR_DATA_NUMBER" != "$number" ] \
    || ! cp "$template" "$FM_PR_POLL_CHECK_TMP" \
    || ! chmod 0600 "$FM_PR_POLL_CHECK_TMP" \
    || ! fm_pr_private_file_valid "$FM_PR_POLL_CHECK_TMP" 600 "$FM_PR_POLL_STATE_DEVICE" \
    || ! cmp -s "$template" "$FM_PR_POLL_CHECK_TMP"; then
    fm_pr_poll_cleanup
    return 1
  fi
  FM_PR_POLL_EXPECT_DATA_HASH=$(fm_pr_sha256 "$FM_PR_POLL_DATA_TMP") || { fm_pr_poll_cleanup; return 1; }
  FM_PR_POLL_EXPECT_TEMPLATE_HASH=$(fm_pr_sha256 "$FM_PR_POLL_CHECK_TMP") || { fm_pr_poll_cleanup; return 1; }
  FM_PR_POLL_EXPECT_DATA_IDENTITY=$(fm_pr_file_identity "$FM_PR_POLL_DATA_TMP") || { fm_pr_poll_cleanup; return 1; }
  FM_PR_POLL_EXPECT_CHECK_IDENTITY=$(fm_pr_file_identity "$FM_PR_POLL_CHECK_TMP") || { fm_pr_poll_cleanup; return 1; }
  if ! printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n' \
      fm-pr-poll-registration-v2 "$id" "$provider" "$url" "$host" "$path" "$number" \
      "$FM_PR_POLL_EXPECT_DATA_HASH" "$FM_PR_POLL_EXPECT_TEMPLATE_HASH" \
      "$FM_PR_POLL_EXPECT_DATA_IDENTITY" "$FM_PR_POLL_EXPECT_CHECK_IDENTITY" \
      > "$FM_PR_POLL_REG_TMP" \
    || ! chmod 0600 "$FM_PR_POLL_REG_TMP" \
    || ! fm_pr_private_file_valid "$FM_PR_POLL_REG_TMP" 600 "$FM_PR_POLL_STATE_DEVICE" \
    || ! fm_pr_poll_registration_parse "$FM_PR_POLL_REG_TMP" \
    || [ "$FM_PR_REG_ID" != "$id" ] \
    || [ "$FM_PR_REG_DATA_HASH" != "$FM_PR_POLL_EXPECT_DATA_HASH" ] \
    || [ "$FM_PR_REG_TEMPLATE_HASH" != "$FM_PR_POLL_EXPECT_TEMPLATE_HASH" ]; then
    fm_pr_poll_cleanup
    return 1
  fi
}

# The caller holds the task's poll publication lock while publishing this
# prepared generation, so no registration can name another generation's files.
fm_pr_poll_publish_prepared() {
  [ -n "$FM_PR_POLL_DATA_TMP" ] && [ -n "$FM_PR_POLL_CHECK_TMP" ] \
    && [ -n "$FM_PR_POLL_REG_TMP" ] || return 1
  fm_pr_regular_destination_on_device_or_absent "$FM_PR_POLL_DATA_DEST" "$FM_PR_POLL_STATE_DEVICE" || return 1
  fm_pr_regular_destination_on_device_or_absent "$FM_PR_POLL_REG_DEST" "$FM_PR_POLL_STATE_DEVICE" || return 1
  fm_pr_regular_destination_on_device_or_absent "$FM_PR_POLL_CHECK_DEST" "$FM_PR_POLL_STATE_DEVICE" || return 1

  if ! mv -f -- "$FM_PR_POLL_DATA_TMP" "$FM_PR_POLL_DATA_DEST"; then
    fm_pr_poll_revoke_final || true
    return 1
  fi
  FM_PR_POLL_DATA_TMP=
  if ! fm_pr_private_file_valid "$FM_PR_POLL_DATA_DEST" 600 "$FM_PR_POLL_STATE_DEVICE" \
    || [ "$(fm_pr_file_identity "$FM_PR_POLL_DATA_DEST")" != "$FM_PR_POLL_EXPECT_DATA_IDENTITY" ] \
    || [ "$(fm_pr_sha256 "$FM_PR_POLL_DATA_DEST")" != "$FM_PR_POLL_EXPECT_DATA_HASH" ] \
    || ! fm_pr_poll_data_parse "$FM_PR_POLL_DATA_DEST" \
    || [ "$FM_PR_DATA_PROVIDER" != "$FM_PR_POLL_EXPECT_PROVIDER" ] \
    || [ "$FM_PR_DATA_URL" != "$FM_PR_POLL_EXPECT_URL" ] \
    || [ "$FM_PR_DATA_HOST" != "$FM_PR_POLL_EXPECT_HOST" ] \
    || [ "$FM_PR_DATA_PATH" != "$FM_PR_POLL_EXPECT_PATH" ] \
    || [ "$FM_PR_DATA_NUMBER" != "$FM_PR_POLL_EXPECT_NUMBER" ]; then
    fm_pr_poll_revoke_final || true
    return 1
  fi

  if ! mv -f -- "$FM_PR_POLL_REG_TMP" "$FM_PR_POLL_REG_DEST"; then
    fm_pr_poll_revoke_final || true
    return 1
  fi
  FM_PR_POLL_REG_TMP=
  if ! fm_pr_private_file_valid "$FM_PR_POLL_REG_DEST" 600 "$FM_PR_POLL_STATE_DEVICE" \
    || ! fm_pr_poll_registration_parse "$FM_PR_POLL_REG_DEST" \
    || [ "$FM_PR_REG_ID" != "$FM_PR_POLL_EXPECT_ID" ] \
    || [ "$FM_PR_REG_PROVIDER" != "$FM_PR_POLL_EXPECT_PROVIDER" ] \
    || [ "$FM_PR_REG_URL" != "$FM_PR_POLL_EXPECT_URL" ] \
    || [ "$FM_PR_REG_HOST" != "$FM_PR_POLL_EXPECT_HOST" ] \
    || [ "$FM_PR_REG_PATH" != "$FM_PR_POLL_EXPECT_PATH" ] \
    || [ "$FM_PR_REG_NUMBER" != "$FM_PR_POLL_EXPECT_NUMBER" ] \
    || [ "$FM_PR_REG_DATA_HASH" != "$FM_PR_POLL_EXPECT_DATA_HASH" ] \
    || [ "$FM_PR_REG_TEMPLATE_HASH" != "$FM_PR_POLL_EXPECT_TEMPLATE_HASH" ] \
    || [ "$FM_PR_REG_DATA_IDENTITY" != "$FM_PR_POLL_EXPECT_DATA_IDENTITY" ] \
    || [ "$FM_PR_REG_CHECK_IDENTITY" != "$FM_PR_POLL_EXPECT_CHECK_IDENTITY" ]; then
    fm_pr_poll_revoke_final || true
    return 1
  fi

  if ! fm_pr_regular_destination_on_device_or_absent "$FM_PR_POLL_CHECK_DEST" "$FM_PR_POLL_STATE_DEVICE" \
    || ! mv -f -- "$FM_PR_POLL_CHECK_TMP" "$FM_PR_POLL_CHECK_DEST"; then
    fm_pr_poll_revoke_final || true
    return 1
  fi
  FM_PR_POLL_CHECK_TMP=
  if ! fm_pr_poll_artifacts_valid "${FM_PR_POLL_CHECK_DEST%/*}" "$FM_PR_POLL_EXPECT_ID" "$FM_PR_POLL_TEMPLATE"; then
    fm_pr_poll_revoke_final || true
    return 1
  fi
}

fm_pr_poll_artifacts_valid() {
  local state=$1 id=$2 template=$3 data_identity check_identity
  fm_pr_poll_artifacts_content_valid "$state" "$id" "$template" || return 1
  data_identity=$(fm_pr_file_identity "$state/$id.pr-poll") || return 1
  check_identity=$(fm_pr_file_identity "$state/$id.check.sh") || return 1
  # The recorded identities bind the registration to the exact sidecar and
  # check file objects published in its own transaction, so a byte-identical
  # replacement or a torn re-arm pairing one generation's check with another's
  # registration is refused.
  [ "$FM_PR_REG_DATA_IDENTITY" = "$data_identity" ] || return 1
  [ "$FM_PR_REG_CHECK_IDENTITY" = "$check_identity" ]
}

# Everything fm_pr_poll_artifacts_valid proves except that the registration's
# recorded file identities name the live sidecar and check. Success alone is
# never authentication. On success FM_PR_DATA_*, FM_PR_REG_*, and FM_PR_META_*
# hold the parsed records.
fm_pr_poll_artifacts_content_valid() {
  local state=$1 id=$2 template=$3 state_device check data registration meta data_hash template_hash
  fm_pr_task_id_valid "$id" || return 1
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  state_device=$(fm_pr_file_device "$state") || return 1
  check="$state/$id.check.sh"
  data="$state/$id.pr-poll"
  registration="$state/$id.pr-poll-registration"
  meta="$state/$id.meta"
  fm_pr_private_file_valid "$check" 600 "$state_device" || return 1
  fm_pr_private_file_valid "$data" 600 "$state_device" || return 1
  fm_pr_private_file_valid "$registration" 600 "$state_device" || return 1
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  [ "$(fm_pr_file_link_count "$meta")" = 1 ] || return 1
  cmp -s "$template" "$check" || return 1
  fm_pr_poll_data_parse "$data" || return 1
  data_hash=$(fm_pr_sha256 "$data") || return 1
  template_hash=$(fm_pr_sha256 "$check") || return 1
  fm_pr_poll_registration_parse "$registration" || return 1
  [ "$FM_PR_REG_ID" = "$id" ] || return 1
  [ "$FM_PR_REG_PROVIDER" = "$FM_PR_DATA_PROVIDER" ] || return 1
  [ "$FM_PR_REG_URL" = "$FM_PR_DATA_URL" ] || return 1
  [ "$FM_PR_REG_HOST" = "$FM_PR_DATA_HOST" ] || return 1
  [ "$FM_PR_REG_PATH" = "$FM_PR_DATA_PATH" ] || return 1
  [ "$FM_PR_REG_NUMBER" = "$FM_PR_DATA_NUMBER" ] || return 1
  [ "$FM_PR_REG_DATA_HASH" = "$data_hash" ] || return 1
  [ "$FM_PR_REG_TEMPLATE_HASH" = "$template_hash" ] || return 1
  fm_pr_metadata_identity_parse "$meta" || return 1
  [ "$FM_PR_META_PROVIDER" = "$FM_PR_DATA_PROVIDER" ] || return 1
  [ "$FM_PR_META_URL" = "$FM_PR_DATA_URL" ] || return 1
  [ "$FM_PR_META_HOST" = "$FM_PR_DATA_HOST" ] || return 1
  [ "$FM_PR_META_PATH" = "$FM_PR_DATA_PATH" ] || return 1
  [ "$FM_PR_META_NUMBER" = "$FM_PR_DATA_NUMBER" ]
}

# A registration armed before a volume remount can name a device number the
# kernel has since reassigned (fm_pr_file_identity). This proves that is the
# only difference: every artifact passes fm_pr_poll_artifacts_content_valid, so
# the check is byte-identical to the template, both hashes match, and the three
# poll artifacts are private, single-link, and on the state directory's live
# device; both recorded identities name one device; each recorded inode equals
# its live inode; and that recorded device differs from the live one. A
# replaced, altered, re-moded, relinked, or foreign-device artifact fails a proof
# here and stays refused. A pending retirement receipt owns its artifacts, so
# none is re-recorded while one exists. On success
# FM_PR_POLL_REARM_DATA_IDENTITY and FM_PR_POLL_REARM_CHECK_IDENTITY hold the
# live identities.
fm_pr_poll_registration_device_shifted() {  # <state> <id> <template>
  local state=$1 id=$2 template=$3 state_device recorded_device receipt data_identity check_identity
  FM_PR_POLL_REARM_DATA_IDENTITY=
  FM_PR_POLL_REARM_CHECK_IDENTITY=
  fm_pr_task_id_valid "$id" || return 1
  [ -f "$state/$id.pr-poll-registration" ] || return 1
  receipt="$state/$id.pr-poll-retirement"
  [ ! -e "$receipt" ] && [ ! -L "$receipt" ] || return 1
  fm_pr_poll_artifacts_content_valid "$state" "$id" "$template" || return 1
  state_device=$(fm_pr_file_device "$state") || return 1
  data_identity=$(fm_pr_file_identity "$state/$id.pr-poll") || return 1
  check_identity=$(fm_pr_file_identity "$state/$id.check.sh") || return 1
  recorded_device=${FM_PR_REG_DATA_IDENTITY%%:*}
  [ "${FM_PR_REG_CHECK_IDENTITY%%:*}" = "$recorded_device" ] || return 1
  [ "$recorded_device" != "$state_device" ] || return 1
  [ "$data_identity" = "$state_device:${FM_PR_REG_DATA_IDENTITY#*:}" ] || return 1
  [ "$check_identity" = "$state_device:${FM_PR_REG_CHECK_IDENTITY#*:}" ] || return 1
  FM_PR_POLL_REARM_DATA_IDENTITY=$data_identity
  FM_PR_POLL_REARM_CHECK_IDENTITY=$check_identity
}

# Rewrite a device-shifted registration (fm_pr_poll_registration_device_shifted)
# so it names the live device, changing no other line. The caller holds the
# task's control lock and poll publication lock, which serialize this with the
# watcher's validated check and retirement, teardown, bin/fm-pr-merge.sh, and
# direct bin/fm-pr-check.sh publication. The proof is repeated just before the
# rename, which proceeds only while the registration is still the exact file
# object and bytes first proven.
# Success means the strict fm_pr_poll_artifacts_valid accepts the result.
fm_pr_poll_registration_rerecord_device() {  # <state> <id> <template>
  local state=$1 id=$2 template=$3 state_device registration tmp reg_hash reg_identity
  local id_line provider url host path number data_hash template_hash data_identity check_identity
  fm_pr_poll_registration_device_shifted "$state" "$id" "$template" || return 1
  registration="$state/$id.pr-poll-registration"
  id_line=$FM_PR_REG_ID
  provider=$FM_PR_REG_PROVIDER
  url=$FM_PR_REG_URL
  host=$FM_PR_REG_HOST
  path=$FM_PR_REG_PATH
  number=$FM_PR_REG_NUMBER
  data_hash=$FM_PR_REG_DATA_HASH
  template_hash=$FM_PR_REG_TEMPLATE_HASH
  data_identity=$FM_PR_POLL_REARM_DATA_IDENTITY
  check_identity=$FM_PR_POLL_REARM_CHECK_IDENTITY
  state_device=$(fm_pr_file_device "$state") || return 1
  reg_hash=$(fm_pr_sha256 "$registration") || return 1
  reg_identity=$(fm_pr_file_identity "$registration") || return 1
  tmp=$(mktemp "$state/.fm-pr-poll-registration.XXXXXX") || return 1
  if ! printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n' \
      fm-pr-poll-registration-v2 "$id_line" "$provider" "$url" "$host" "$path" "$number" \
      "$data_hash" "$template_hash" "$data_identity" "$check_identity" > "$tmp" \
    || ! chmod 0600 "$tmp" \
    || ! fm_pr_private_file_valid "$tmp" 600 "$state_device" \
    || ! fm_pr_poll_registration_parse "$tmp" \
    || [ "$FM_PR_REG_ID" != "$id" ] \
    || [ "$FM_PR_REG_URL" != "$url" ] \
    || [ "$FM_PR_REG_DATA_HASH" != "$data_hash" ] \
    || [ "$FM_PR_REG_TEMPLATE_HASH" != "$template_hash" ] \
    || [ "$FM_PR_REG_DATA_IDENTITY" != "$data_identity" ] \
    || [ "$FM_PR_REG_CHECK_IDENTITY" != "$check_identity" ] \
    || ! fm_pr_poll_registration_device_shifted "$state" "$id" "$template" \
    || [ "$FM_PR_POLL_REARM_DATA_IDENTITY" != "$data_identity" ] \
    || [ "$FM_PR_POLL_REARM_CHECK_IDENTITY" != "$check_identity" ] \
    || [ "$(fm_pr_sha256 "$registration")" != "$reg_hash" ] \
    || [ "$(fm_pr_file_identity "$registration")" != "$reg_identity" ] \
    || ! fm_pr_regular_destination_on_device_or_absent "$registration" "$state_device" \
    || ! mv -f -- "$tmp" "$registration"; then
    rm -f -- "$tmp"
    return 1
  fi
  fm_pr_poll_artifacts_valid "$state" "$id" "$template"
}

fm_pr_poll_snapshot_capture() {
  local state=$1 id=$2 template=$3 registration
  fm_pr_poll_artifacts_valid "$state" "$id" "$template" || return 1
  registration="$state/$id.pr-poll-registration"
  FM_PR_POLL_SNAPSHOT_REG_HASH=$(fm_pr_sha256 "$registration") || return 1
  FM_PR_POLL_SNAPSHOT_REG_IDENTITY=$(fm_pr_file_identity "$registration") || return 1
  FM_PR_POLL_SNAPSHOT_ID=$id
  FM_PR_POLL_SNAPSHOT_PROVIDER=$FM_PR_DATA_PROVIDER
  FM_PR_POLL_SNAPSHOT_URL=$FM_PR_DATA_URL
  FM_PR_POLL_SNAPSHOT_HOST=$FM_PR_DATA_HOST
  FM_PR_POLL_SNAPSHOT_PATH=$FM_PR_DATA_PATH
  FM_PR_POLL_SNAPSHOT_NUMBER=$FM_PR_DATA_NUMBER
  FM_PR_POLL_SNAPSHOT_DATA_HASH=$FM_PR_REG_DATA_HASH
  FM_PR_POLL_SNAPSHOT_TEMPLATE_HASH=$FM_PR_REG_TEMPLATE_HASH
  FM_PR_POLL_SNAPSHOT_DATA_IDENTITY=$FM_PR_REG_DATA_IDENTITY
  FM_PR_POLL_SNAPSHOT_CHECK_IDENTITY=$FM_PR_REG_CHECK_IDENTITY
}

fm_pr_poll_snapshot_matches() {
  local state=$1 id=$2 template=$3 registration reg_hash reg_identity
  [ -n "$FM_PR_POLL_SNAPSHOT_ID" ] && [ "$id" = "$FM_PR_POLL_SNAPSHOT_ID" ] || return 1
  fm_pr_poll_artifacts_valid "$state" "$id" "$template" || return 1
  registration="$state/$id.pr-poll-registration"
  reg_hash=$(fm_pr_sha256 "$registration") || return 1
  reg_identity=$(fm_pr_file_identity "$registration") || return 1
  [ "$FM_PR_DATA_PROVIDER" = "$FM_PR_POLL_SNAPSHOT_PROVIDER" ] || return 1
  [ "$FM_PR_DATA_URL" = "$FM_PR_POLL_SNAPSHOT_URL" ] || return 1
  [ "$FM_PR_DATA_HOST" = "$FM_PR_POLL_SNAPSHOT_HOST" ] || return 1
  [ "$FM_PR_DATA_PATH" = "$FM_PR_POLL_SNAPSHOT_PATH" ] || return 1
  [ "$FM_PR_DATA_NUMBER" = "$FM_PR_POLL_SNAPSHOT_NUMBER" ] || return 1
  [ "$FM_PR_REG_DATA_HASH" = "$FM_PR_POLL_SNAPSHOT_DATA_HASH" ] || return 1
  [ "$FM_PR_REG_TEMPLATE_HASH" = "$FM_PR_POLL_SNAPSHOT_TEMPLATE_HASH" ] || return 1
  [ "$FM_PR_REG_DATA_IDENTITY" = "$FM_PR_POLL_SNAPSHOT_DATA_IDENTITY" ] || return 1
  [ "$FM_PR_REG_CHECK_IDENTITY" = "$FM_PR_POLL_SNAPSHOT_CHECK_IDENTITY" ] || return 1
  [ "$reg_hash" = "$FM_PR_POLL_SNAPSHOT_REG_HASH" ] || return 1
  [ "$reg_identity" = "$FM_PR_POLL_SNAPSHOT_REG_IDENTITY" ]
}

fm_pr_poll_retirement_parse() {
  local file=$1 version id provider url host path number data_hash template_hash
  local data_identity check_identity reg_hash reg_identity result _extra
  FM_PR_RETIRE_ID=
  FM_PR_RETIRE_PROVIDER=
  FM_PR_RETIRE_URL=
  FM_PR_RETIRE_HOST=
  FM_PR_RETIRE_PATH=
  FM_PR_RETIRE_NUMBER=
  FM_PR_RETIRE_DATA_HASH=
  FM_PR_RETIRE_TEMPLATE_HASH=
  FM_PR_RETIRE_DATA_IDENTITY=
  FM_PR_RETIRE_CHECK_IDENTITY=
  FM_PR_RETIRE_REG_HASH=
  FM_PR_RETIRE_REG_IDENTITY=
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  exec 9< "$file" || return 1
  IFS= read -r version <&9 || { exec 9<&-; return 1; }
  IFS= read -r id <&9 || { exec 9<&-; return 1; }
  IFS= read -r provider <&9 || { exec 9<&-; return 1; }
  IFS= read -r url <&9 || { exec 9<&-; return 1; }
  IFS= read -r host <&9 || { exec 9<&-; return 1; }
  IFS= read -r path <&9 || { exec 9<&-; return 1; }
  IFS= read -r number <&9 || { exec 9<&-; return 1; }
  IFS= read -r data_hash <&9 || { exec 9<&-; return 1; }
  IFS= read -r template_hash <&9 || { exec 9<&-; return 1; }
  IFS= read -r data_identity <&9 || { exec 9<&-; return 1; }
  IFS= read -r check_identity <&9 || { exec 9<&-; return 1; }
  IFS= read -r reg_hash <&9 || { exec 9<&-; return 1; }
  IFS= read -r reg_identity <&9 || { exec 9<&-; return 1; }
  IFS= read -r result <&9 || { exec 9<&-; return 1; }
  if IFS= read -r _extra <&9; then
    exec 9<&-
    return 1
  fi
  exec 9<&-
  [ "$version" = fm-pr-poll-retirement-v1 ] || return 1
  fm_pr_task_id_valid "$id" || return 1
  fm_pr_url_parse "$url" || return 1
  [ "$provider" = "$FM_PR_PROVIDER" ] || return 1
  [ "$host" = "$FM_PR_HOST" ] || return 1
  [ "$path" = "$FM_PR_PATH" ] || return 1
  [ "$number" = "$FM_PR_NUMBER" ] || return 1
  [[ "$data_hash" =~ ^[0-9a-f]{64}$ ]] || return 1
  [[ "$template_hash" =~ ^[0-9a-f]{64}$ ]] || return 1
  [[ "$data_identity" =~ ^[0-9]+:[0-9]+$ ]] || return 1
  [[ "$check_identity" =~ ^[0-9]+:[0-9]+$ ]] || return 1
  [[ "$reg_hash" =~ ^[0-9a-f]{64}$ ]] || return 1
  [[ "$reg_identity" =~ ^[0-9]+:[0-9]+$ ]] || return 1
  [ "$result" = merged ] || return 1
  FM_PR_RETIRE_ID=$id
  FM_PR_RETIRE_PROVIDER=$provider
  FM_PR_RETIRE_URL=$url
  FM_PR_RETIRE_HOST=$host
  FM_PR_RETIRE_PATH=$path
  FM_PR_RETIRE_NUMBER=$number
  FM_PR_RETIRE_DATA_HASH=$data_hash
  FM_PR_RETIRE_TEMPLATE_HASH=$template_hash
  FM_PR_RETIRE_DATA_IDENTITY=$data_identity
  FM_PR_RETIRE_CHECK_IDENTITY=$check_identity
  FM_PR_RETIRE_REG_HASH=$reg_hash
  FM_PR_RETIRE_REG_IDENTITY=$reg_identity
}

fm_pr_poll_retirement_receipt_valid() {
  local state=$1 id=$2 receipt state_device meta
  fm_pr_task_id_valid "$id" || return 1
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  state_device=$(fm_pr_file_device "$state") || return 1
  receipt="$state/$id.pr-poll-retirement"
  fm_pr_private_file_valid "$receipt" 600 "$state_device" || return 1
  fm_pr_poll_retirement_parse "$receipt" || return 1
  [ "$FM_PR_RETIRE_ID" = "$id" ] || return 1
  meta="$state/$id.meta"
  fm_pr_metadata_identity_parse "$meta" || return 1
  [ "$FM_PR_META_PROVIDER" = "$FM_PR_RETIRE_PROVIDER" ] || return 1
  [ "$FM_PR_META_URL" = "$FM_PR_RETIRE_URL" ] || return 1
  [ "$FM_PR_META_HOST" = "$FM_PR_RETIRE_HOST" ] || return 1
  [ "$FM_PR_META_PATH" = "$FM_PR_RETIRE_PATH" ] || return 1
  [ "$FM_PR_META_NUMBER" = "$FM_PR_RETIRE_NUMBER" ] || return 1
  FM_PR_RETIRE_RECEIPT_HASH=$(fm_pr_sha256 "$receipt") || return 1
  FM_PR_RETIRE_RECEIPT_IDENTITY=$(fm_pr_file_identity "$receipt") || return 1
}

fm_pr_github_read_record_with_gh() {  # <owner> <repo> <number>
  local owner=$1 repo=$2 number=$3 fields line total=0 named=0
  local state='' merged=''
  FM_PR_RECORD_STATE=
  FM_PR_RECORD_MERGED=

  # shellcheck disable=SC2016  # GraphQL variables are literal query syntax.
  if ! fields=$(gh api graphql \
    -f query='query($owner:String!,$repo:String!,$number:Int!){repository(owner:$owner,name:$repo){pullRequest(number:$number){state merged}}}' \
    -F "owner=$owner" -F "repo=$repo" -F "number=$number" \
    --jq '.data.repository.pullRequest | "state=" + (.state // ""), "merged=" + (.merged | tostring)' \
    2>/dev/null) || [ -z "$fields" ]; then
    return 1
  fi
  while IFS= read -r line; do
    total=$((total + 1))
    case "$line" in
      state=*) state=${line#state=} ;;
      merged=*) merged=${line#merged=} ;;
      *) continue ;;
    esac
    named=$((named + 1))
  done <<FIELDS
$fields
FIELDS
  if [ "$named" -ne 2 ] || [ "$total" -ne 2 ] || [ -z "$state" ] \
    || { [ "$merged" != true ] && [ "$merged" != false ]; }; then
    return 1
  fi

  # Consumed by bin/fm-crew-state.sh passed_pr_detail.
  # shellcheck disable=SC2034
  FM_PR_RECORD_STATE=$state
  # Consumed by bin/fm-crew-state.sh passed_pr_detail.
  # shellcheck disable=SC2034
  FM_PR_RECORD_MERGED=$merged
}

fm_pr_github_read_record_with_gh_axi() {  # <owner> <repo> <number>
  local owner=$1 repo=$2 number=$3 output state
  FM_PR_RECORD_STATE=
  FM_PR_RECORD_MERGED=
  if ! output=$(gh-axi pr view "$number" --repo "$owner/$repo" 2>/dev/null); then
    return 1
  fi
  if ! state=$(printf '%s\n' "$output" | awk '
    $1 == "state:" { count++; value=$2 }
    END { if (count == 1 && value != "") print value; else exit 1 }
  '); then
    return 1
  fi
  case "$state" in
    MERGED|merged)
      # Consumed by bin/fm-crew-state.sh passed_pr_detail.
      # shellcheck disable=SC2034
      FM_PR_RECORD_STATE=MERGED
      # Consumed by bin/fm-crew-state.sh passed_pr_detail.
      # shellcheck disable=SC2034
      FM_PR_RECORD_MERGED=true
      ;;
    OPEN|open)
      # Consumed by bin/fm-crew-state.sh passed_pr_detail.
      # shellcheck disable=SC2034
      FM_PR_RECORD_STATE=OPEN
      # Consumed by bin/fm-crew-state.sh passed_pr_detail.
      # shellcheck disable=SC2034
      FM_PR_RECORD_MERGED=false
      ;;
    CLOSED|closed)
      # Consumed by bin/fm-crew-state.sh passed_pr_detail.
      # shellcheck disable=SC2034
      FM_PR_RECORD_STATE=CLOSED
      # Consumed by bin/fm-crew-state.sh passed_pr_detail.
      # shellcheck disable=SC2034
      FM_PR_RECORD_MERGED=false
      ;;
    *)
      return 1
      ;;
  esac
}

fm_pr_github_read_record() {  # <owner> <repo> <number>
  if command -v gh >/dev/null 2>&1 && fm_pr_github_read_record_with_gh "$@"; then
    return 0
  fi
  command -v gh-axi >/dev/null 2>&1 || return 1
  fm_pr_github_read_record_with_gh_axi "$@"
}

fm_pr_gitlab_read_record() {  # <host> <path> <number>
  local host=$1 path=$2 number=$3 project_url json fields line
  local total=0 named=0 state='' merged=''
  FM_PR_RECORD_STATE=
  FM_PR_RECORD_MERGED=
  command -v glab >/dev/null 2>&1 || return 1
  command -v jq >/dev/null 2>&1 || return 1
  project_url="https://$host/$path"

  if ! json=$(GITLAB_HOST="$host" glab mr view "$number" -R "$project_url" -F json 2>/dev/null) \
    || [ -z "$json" ]; then
    return 1
  fi
  if ! fields=$(printf '%s' "$json" | jq -r '
      if type == "object" and (.state | type == "string") and .state != "" then
        "state=" + .state,
        "merged=" + (if .state == "merged" then "true" else "false" end)
      else
        error("invalid merge request state")
      end' 2>/dev/null); then
    return 1
  fi
  while IFS= read -r line; do
    total=$((total + 1))
    case "$line" in
      state=*) state=${line#state=} ;;
      merged=*) merged=${line#merged=} ;;
      *) continue ;;
    esac
    named=$((named + 1))
  done <<FIELDS
$fields
FIELDS
  if [ "$named" -ne 2 ] || [ "$total" -ne 2 ] || [ -z "$state" ] \
    || { [ "$merged" != true ] && [ "$merged" != false ]; }; then
    return 1
  fi

  # Consumed by bin/fm-crew-state.sh passed_pr_detail.
  # shellcheck disable=SC2034
  FM_PR_RECORD_STATE=$state
  # Consumed by bin/fm-crew-state.sh passed_pr_detail.
  # shellcheck disable=SC2034
  FM_PR_RECORD_MERGED=$merged
}

# gerrit-axi resolves its server from the current directory's origin remote
# first, so the host is passed explicitly from the parsed identity and a read
# outside a clone still reaches the right server. A change number is
# server-global and --host pins the server, so the number alone names the
# change and the project path is not part of the read. Prints the one record
# whose change number is exactly <number> as compact JSON, and fails on any
# other reading. The record's own url field is not compared against the stored
# URL, because Gerrit composes it from gerrit.canonicalWebUrl and omits it when
# that setting is unset, which would turn every read on such a server into a
# permanent unknown.
fm_pr_gerrit_read_change() {  # <host> <number>
  local host=$1 number=$2 json
  command -v gerrit-axi >/dev/null 2>&1 || return 1
  command -v jq >/dev/null 2>&1 || return 1
  case "$number" in
    ''|*[!0-9]*) return 1 ;;
  esac
  if ! json=$(gerrit-axi show "$number" --host "$host" --json 2>/dev/null) \
    || [ -z "$json" ]; then
    return 1
  fi
  printf '%s' "$json" | jq -c --argjson change "$number" '
    if type == "object" and .ok == true and (.changes | type) == "array" then
      [.changes[] | select((.change | type) == "number" and .change == $change)] as $match
      | if ($match | length) == 1 and ($match[0] | type) == "object"
        then $match[0]
        else error("no exact change record")
        end
    else
      error("invalid gerrit record")
    end' 2>/dev/null
}

# The status of one Gerrit change. The status is the only field read: a merged
# change and an approved-but-unsubmitted one report the same submit,
# submittable, and blocked_on values, so only the status separates them.
fm_pr_gerrit_read_record() {  # <host> <number>
  local record state merged=false
  FM_PR_RECORD_STATE=
  FM_PR_RECORD_MERGED=
  record=$(fm_pr_gerrit_read_change "$1" "$2") || return 1
  state=$(printf '%s' "$record" | jq -r '
    if (.status | type) == "string" and .status != "" and (.status | test("\n") | not)
    then .status
    else error("no status")
    end' 2>/dev/null) || return 1
  [ -n "$state" ] || return 1
  [ "$state" != MERGED ] || merged=true

  # Consumed by bin/fm-crew-state.sh passed_pr_detail.
  # shellcheck disable=SC2034
  FM_PR_RECORD_STATE=$state
  # Consumed by bin/fm-crew-state.sh passed_pr_detail.
  # shellcheck disable=SC2034
  FM_PR_RECORD_MERGED=$merged
}

# The current patch set revision of one Gerrit change, read from the same exact
# record as its status above. Consumed by bin/fm-dod-lib.sh's named-head gate,
# which accepts a published change only when this revision carries the worker
# copy's HEAD tree. It is a live read and never a recorded pr_head: the next
# amend replaces it.
fm_pr_gerrit_read_revision() {  # <host> <number>
  local record revision
  FM_PR_RECORD_REVISION=
  record=$(fm_pr_gerrit_read_change "$1" "$2") || return 1
  revision=$(printf '%s' "$record" | jq -r '
    if (.revision | type) == "string" then .revision else error("no revision") end' 2>/dev/null) \
    || return 1
  fm_pr_head_valid "$revision" || return 1
  # Consumed by bin/fm-dod-lib.sh fm_dod_gerrit_change_carries_head.
  # shellcheck disable=SC2034
  FM_PR_RECORD_REVISION=$revision
}

# Gitea is read and merged only through tea, the Gitea CLI, and only through a
# tea login whose configured URL is exactly the pull request's origin. The login
# is resolved by that match on every call rather than recorded, so no login name
# or credential is ever stored in task state, and a pull request URL naming a
# server with no such login reaches nothing: zero matches and an ambiguous
# several both refuse. tea holds the token; firstmate never reads it.
# Prints the one matching login name.
fm_pr_gitea_login() {  # <origin>
  local origin=${1-} json name
  command -v tea >/dev/null 2>&1 || return 1
  command -v jq >/dev/null 2>&1 || return 1
  [ -n "$origin" ] || return 1
  json=$(cd / && tea logins list --output json 2>/dev/null) || return 1
  name=$(printf '%s' "$json" | jq -r --arg origin "$origin" '
    if type != "array" then error("invalid logins") else . end
    | [ .[]
        | select(type == "object" and (.url | type) == "string" and (.name | type) == "string")
        | select((.url | sub("/+$"; "")) == $origin)
        | .name ]
    | if length == 1 and (.[0] | test("^[A-Za-z0-9][A-Za-z0-9._-]*$"))
      then .[0]
      else error("no unique login")
      end' 2>/dev/null) || return 1
  [ -n "$name" ] || return 1
  printf '%s\n' "$name"
}

# One authenticated Gitea API request through the matched tea login.
# tea api exits zero on an HTTP error status and prints the error body as if it
# were the answer, so the status is read from the one HTTP status line that
# --include writes to stderr, and only a 2xx status succeeds. The response body
# is written to <body-out>. Sets FM_PR_GITEA_STATUS to the HTTP status (empty
# when none was read) and FM_PR_GITEA_TOTAL to the X-Total-Count header, which
# is the only whole-list count Gitea reports for a paginated list.
# Only GET and POST against /api/v1/repos/ are accepted, so this cannot be used
# to address any other endpoint family; tea runs from / so no repository
# context in the caller's directory can redirect it.
FM_PR_GITEA_STATUS=
FM_PR_GITEA_TOTAL=
fm_pr_gitea_api() {  # <origin> <GET|POST> <api-path> <body-out> [request-json-file]
  local origin=$1 method=$2 api_path=$3 body_out=$4 request=${5-} login headers status total
  local -a args
  FM_PR_GITEA_STATUS=
  FM_PR_GITEA_TOTAL=
  case "$method" in GET|POST) ;; *) return 1 ;; esac
  case "$api_path" in
    /api/v1/repos/*) ;;
    *) return 1 ;;
  esac
  # A segment name read back from the server, such as a base branch, is part of
  # some paths, so dot segments and empty segments are refused here rather than
  # left for an HTTP client to normalize into another endpoint.
  case "$api_path" in
    *[!A-Za-z0-9._/?\&=-]*|*//*|*/./*|*/../*|*/.|*/..) return 1 ;;
  esac
  login=$(fm_pr_gitea_login "$origin") || return 1
  headers=$(mktemp "${TMPDIR:-/tmp}/fm-pr-gitea-headers.XXXXXX") || return 1
  args=(api --login "$login" --include --method "$method")
  [ -z "$request" ] || args+=(--data "@$request")
  args+=("$api_path")
  if ! (cd / && tea "${args[@]}") >"$body_out" 2>"$headers"; then
    rm -f -- "$headers"
    return 1
  fi
  status=$(tr -d '\r' < "$headers" | awk '
    /^HTTP\/[0-9.]+ [0-9][0-9][0-9]( |$)/ { count++; code=$2 }
    END { if (count == 1) print code; else exit 1 }') || { rm -f -- "$headers"; return 1; }
  total=$(tr -d '\r' < "$headers" | awk '
    tolower($1) == "x-total-count:" { count++; value=$2 }
    END { if (count == 1 && value ~ /^[0-9]+$/) print value }')
  rm -f -- "$headers"
  FM_PR_GITEA_STATUS=$status
  # shellcheck disable=SC2034  # Read by callers of this helper.
  FM_PR_GITEA_TOTAL=$total
  case "$status" in
    2[0-9][0-9]) return 0 ;;
  esac
  return 1
}

# Prints one live Gitea pull request as compact JSON after checking that it is
# an object for exactly <number>, so an error body or another pull request can
# never be read as this one.
fm_pr_gitea_read_pull() {  # <origin> <path> <number>
  local origin=$1 path=$2 number=$3 body json
  fm_pr_gitea_path_valid "$path" || return 1
  case "$number" in
    ''|0*|*[!0-9]*) return 1 ;;
  esac
  body=$(mktemp "${TMPDIR:-/tmp}/fm-pr-gitea-body.XXXXXX") || return 1
  if ! fm_pr_gitea_api "$origin" GET "/api/v1/repos/$path/pulls/$number" "$body"; then
    rm -f -- "$body"
    return 1
  fi
  json=$(jq -c --argjson number "$number" '
    if type == "object" and .number == $number then . else error("not this pull request") end'     < "$body" 2>/dev/null) || { rm -f -- "$body"; return 1; }
  rm -f -- "$body"
  printf '%s\n' "$json"
}

# The merged state of one Gitea pull request. merged is read from Gitea's own
# boolean rather than inferred from the state, because a merged pull request is
# also closed and a closed one need not be merged.
fm_pr_gitea_read_record() {  # <origin> <path> <number>
  local json fields state='' merged=''
  FM_PR_RECORD_STATE=
  FM_PR_RECORD_MERGED=
  json=$(fm_pr_gitea_read_pull "$1" "$2" "$3") || return 1
  fields=$(printf '%s' "$json" | jq -r '
    if (.state | type) == "string" and (.state == "open" or .state == "closed")
       and (.merged | type) == "boolean"
    then (if .merged then "MERGED" else (.state | ascii_upcase) end) + " " + (.merged | tostring)
    else error("invalid pull request state")
    end' 2>/dev/null) || return 1
  state=${fields% *}
  merged=${fields#* }
  [ -n "$state" ] || return 1
  [ "$merged" = true ] || [ "$merged" = false ] || return 1
  # Consumed by bin/fm-crew-state.sh passed_pr_detail.
  # shellcheck disable=SC2034
  FM_PR_RECORD_STATE=$state
  # Consumed by bin/fm-crew-state.sh passed_pr_detail.
  # shellcheck disable=SC2034
  FM_PR_RECORD_MERGED=$merged
}

# Prints every latest commit status at exactly <sha> as a compact JSON array of
# {context, status}. Gitea's combined status endpoint already keeps only the
# latest status per context, so no supersession rule is needed, but it is
# paginated and its body total_count counts only the current page, so pages are
# read until the X-Total-Count header's whole-list count is reached. A short or
# empty page before that count, a count that is absent or changes between pages,
# a body whose sha is not <sha>, or more pages than the bound all refuse rather
# than return a partial list that could hide a red check.
fm_pr_gitea_read_statuses() {  # <origin> <path> <sha>
  local origin=$1 path=$2 sha=$3 body page=1 total='' collected='[]' items count
  fm_pr_gitea_path_valid "$path" || return 1
  fm_pr_head_valid "$sha" || return 1
  body=$(mktemp "${TMPDIR:-/tmp}/fm-pr-gitea-body.XXXXXX") || return 1
  while :; do
    if ! fm_pr_gitea_api "$origin" GET "/api/v1/repos/$path/commits/$sha/status?limit=50&page=$page" "$body"; then
      rm -f -- "$body"
      return 1
    fi
    if [ -z "$FM_PR_GITEA_TOTAL" ] || { [ -n "$total" ] && [ "$total" != "$FM_PR_GITEA_TOTAL" ]; }; then
      rm -f -- "$body"
      return 1
    fi
    total=$FM_PR_GITEA_TOTAL
    items=$(jq -c --arg sha "$sha" '
      if type == "object" and .sha == $sha
         and (.statuses == null or (.statuses | type) == "array")
      then [ (.statuses // [])[]
             | if type == "object" and (.context | type) == "string" and (.context | length) > 0
                  and (.status | type) == "string"
               then {context, status}
               else error("invalid commit status")
               end ]
      else error("invalid combined status")
      end' < "$body" 2>/dev/null) || { rm -f -- "$body"; return 1; }
    collected=$(jq -cn --argjson a "$collected" --argjson b "$items" '$a + $b') || { rm -f -- "$body"; return 1; }
    count=$(printf '%s' "$collected" | jq 'length') || { rm -f -- "$body"; return 1; }
    [ "$count" -le "$total" ] || { rm -f -- "$body"; return 1; }
    [ "$count" -lt "$total" ] || break
    [ "$(printf '%s' "$items" | jq 'length')" -gt 0 ] || { rm -f -- "$body"; return 1; }
    page=$((page + 1))
    [ "$page" -le 20 ] || { rm -f -- "$body"; return 1; }
  done
  rm -f -- "$body"
  printf '%s' "$collected" | jq -c 'if (map(.context) | unique | length) == length then . else error("duplicate context") end' 2>/dev/null
}

fm_pr_poll_retirement_data_valid() {
  local state=$1 id=$2 state_device data data_hash data_identity
  state_device=$(fm_pr_file_device "$state") || return 1
  data="$state/$id.pr-poll"
  fm_pr_private_file_valid "$data" 600 "$state_device" || return 1
  fm_pr_poll_data_parse "$data" || return 1
  data_hash=$(fm_pr_sha256 "$data") || return 1
  data_identity=$(fm_pr_file_identity "$data") || return 1
  [ "$FM_PR_DATA_PROVIDER" = "$FM_PR_RETIRE_PROVIDER" ] || return 1
  [ "$FM_PR_DATA_URL" = "$FM_PR_RETIRE_URL" ] || return 1
  [ "$FM_PR_DATA_HOST" = "$FM_PR_RETIRE_HOST" ] || return 1
  [ "$FM_PR_DATA_PATH" = "$FM_PR_RETIRE_PATH" ] || return 1
  [ "$FM_PR_DATA_NUMBER" = "$FM_PR_RETIRE_NUMBER" ] || return 1
  [ "$data_hash" = "$FM_PR_RETIRE_DATA_HASH" ] || return 1
  [ "$data_identity" = "$FM_PR_RETIRE_DATA_IDENTITY" ]
}

fm_pr_poll_retirement_registration_valid() {
  local state=$1 id=$2 state_device registration reg_hash reg_identity
  state_device=$(fm_pr_file_device "$state") || return 1
  registration="$state/$id.pr-poll-registration"
  fm_pr_private_file_valid "$registration" 600 "$state_device" || return 1
  fm_pr_poll_registration_parse "$registration" || return 1
  reg_hash=$(fm_pr_sha256 "$registration") || return 1
  reg_identity=$(fm_pr_file_identity "$registration") || return 1
  [ "$FM_PR_REG_ID" = "$id" ] || return 1
  [ "$FM_PR_REG_PROVIDER" = "$FM_PR_RETIRE_PROVIDER" ] || return 1
  [ "$FM_PR_REG_URL" = "$FM_PR_RETIRE_URL" ] || return 1
  [ "$FM_PR_REG_HOST" = "$FM_PR_RETIRE_HOST" ] || return 1
  [ "$FM_PR_REG_PATH" = "$FM_PR_RETIRE_PATH" ] || return 1
  [ "$FM_PR_REG_NUMBER" = "$FM_PR_RETIRE_NUMBER" ] || return 1
  [ "$FM_PR_REG_DATA_HASH" = "$FM_PR_RETIRE_DATA_HASH" ] || return 1
  [ "$FM_PR_REG_TEMPLATE_HASH" = "$FM_PR_RETIRE_TEMPLATE_HASH" ] || return 1
  [ "$FM_PR_REG_DATA_IDENTITY" = "$FM_PR_RETIRE_DATA_IDENTITY" ] || return 1
  [ "$FM_PR_REG_CHECK_IDENTITY" = "$FM_PR_RETIRE_CHECK_IDENTITY" ] || return 1
  [ "$reg_hash" = "$FM_PR_RETIRE_REG_HASH" ] || return 1
  [ "$reg_identity" = "$FM_PR_RETIRE_REG_IDENTITY" ]
}

fm_pr_poll_retirement_check_valid() {
  local state=$1 id=$2 state_device check check_hash check_identity
  state_device=$(fm_pr_file_device "$state") || return 1
  check="$state/$id.check.sh"
  fm_pr_private_file_valid "$check" 600 "$state_device" || return 1
  check_hash=$(fm_pr_sha256 "$check") || return 1
  check_identity=$(fm_pr_file_identity "$check") || return 1
  [ "$check_hash" = "$FM_PR_RETIRE_TEMPLATE_HASH" ] || return 1
  [ "$check_identity" = "$FM_PR_RETIRE_CHECK_IDENTITY" ]
}

fm_pr_poll_retirement_state_valid() {
  local state=$1 id=$2 check data registration has_check=0 has_data=0 has_registration=0
  fm_pr_poll_retirement_receipt_valid "$state" "$id" || return 1
  check="$state/$id.check.sh"
  data="$state/$id.pr-poll"
  registration="$state/$id.pr-poll-registration"
  [ ! -e "$check" ] && [ ! -L "$check" ] || has_check=1
  [ ! -e "$data" ] && [ ! -L "$data" ] || has_data=1
  [ ! -e "$registration" ] && [ ! -L "$registration" ] || has_registration=1
  if [ "$has_check" -eq 1 ]; then
    [ "$has_data" -eq 1 ] && [ "$has_registration" -eq 1 ] || return 1
    fm_pr_poll_retirement_check_valid "$state" "$id" || return 1
    fm_pr_poll_retirement_data_valid "$state" "$id" || return 1
    fm_pr_poll_retirement_registration_valid "$state" "$id" || return 1
    return 0
  fi
  if [ "$has_registration" -eq 1 ]; then
    [ "$has_data" -eq 1 ] || return 1
    fm_pr_poll_retirement_data_valid "$state" "$id" || return 1
    fm_pr_poll_retirement_registration_valid "$state" "$id" || return 1
    return 0
  fi
  [ "$has_data" -eq 0 ] || fm_pr_poll_retirement_data_valid "$state" "$id"
}

fm_pr_poll_retirement_remove_exact() {
  local path=$1 state_device=$2 expected_identity=$3 expected_hash=$4
  fm_pr_private_file_valid "$path" 600 "$state_device" || return 1
  [ "$(fm_pr_file_identity "$path")" = "$expected_identity" ] || return 1
  [ "$(fm_pr_sha256 "$path")" = "$expected_hash" ] || return 1
  rm -f -- "$path" || return 1
  [ ! -e "$path" ] && [ ! -L "$path" ]
}

fm_pr_poll_retirement_discard_obsolete() {
  local state=$1 id=$2 template=$3 receipt registration state_device
  local receipt_hash receipt_identity current_reg_hash current_reg_identity
  fm_pr_task_id_valid "$id" || return 1
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  state_device=$(fm_pr_file_device "$state") || return 1
  receipt="$state/$id.pr-poll-retirement"
  fm_pr_private_file_valid "$receipt" 600 "$state_device" || return 1
  fm_pr_poll_retirement_parse "$receipt" || return 1
  [ "$FM_PR_RETIRE_ID" = "$id" ] || return 1
  receipt_hash=$(fm_pr_sha256 "$receipt") || return 1
  receipt_identity=$(fm_pr_file_identity "$receipt") || return 1
  fm_pr_poll_artifacts_valid "$state" "$id" "$template" || return 1
  registration="$state/$id.pr-poll-registration"
  current_reg_hash=$(fm_pr_sha256 "$registration") || return 1
  current_reg_identity=$(fm_pr_file_identity "$registration") || return 1
  if [ "$current_reg_hash" = "$FM_PR_RETIRE_REG_HASH" ] \
    && [ "$current_reg_identity" = "$FM_PR_RETIRE_REG_IDENTITY" ] \
    && [ "$FM_PR_REG_DATA_IDENTITY" = "$FM_PR_RETIRE_DATA_IDENTITY" ] \
    && [ "$FM_PR_REG_CHECK_IDENTITY" = "$FM_PR_RETIRE_CHECK_IDENTITY" ]; then
    return 1
  fi
  fm_pr_poll_retirement_remove_exact "$receipt" "$state_device" \
    "$receipt_identity" "$receipt_hash"
}

fm_pr_poll_retirement_publish() {
  local state=$1 id=$2 template=$3 result=$4 receipt state_device tmp
  [ "$result" = merged ] || return 1
  fm_pr_poll_snapshot_matches "$state" "$id" "$template" || return 1
  state_device=$(fm_pr_file_device "$state") || return 1
  receipt="$state/$id.pr-poll-retirement"
  fm_pr_regular_destination_on_device_or_absent "$receipt" "$state_device" || return 1
  [ ! -e "$receipt" ] && [ ! -L "$receipt" ] || return 1
  umask 077
  tmp=$(mktemp "$state/.fm-pr-poll-retirement.XXXXXX") || return 1
  if ! printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n' \
      fm-pr-poll-retirement-v1 \
      "$FM_PR_POLL_SNAPSHOT_ID" \
      "$FM_PR_POLL_SNAPSHOT_PROVIDER" \
      "$FM_PR_POLL_SNAPSHOT_URL" \
      "$FM_PR_POLL_SNAPSHOT_HOST" \
      "$FM_PR_POLL_SNAPSHOT_PATH" \
      "$FM_PR_POLL_SNAPSHOT_NUMBER" \
      "$FM_PR_POLL_SNAPSHOT_DATA_HASH" \
      "$FM_PR_POLL_SNAPSHOT_TEMPLATE_HASH" \
      "$FM_PR_POLL_SNAPSHOT_DATA_IDENTITY" \
      "$FM_PR_POLL_SNAPSHOT_CHECK_IDENTITY" \
      "$FM_PR_POLL_SNAPSHOT_REG_HASH" \
      "$FM_PR_POLL_SNAPSHOT_REG_IDENTITY" \
      merged > "$tmp" \
    || ! chmod 0600 "$tmp" \
    || ! fm_pr_private_file_valid "$tmp" 600 "$state_device" \
    || ! fm_pr_poll_retirement_parse "$tmp" \
    || [ "$FM_PR_RETIRE_ID" != "$id" ] \
    || ! fm_pr_poll_snapshot_matches "$state" "$id" "$template" \
    || ! fm_pr_regular_destination_on_device_or_absent "$receipt" "$state_device" \
    || [ -e "$receipt" ] || [ -L "$receipt" ] \
    || ! mv -f -- "$tmp" "$receipt"; then
    rm -f -- "$tmp"
    return 1
  fi
  fm_pr_poll_retirement_receipt_valid "$state" "$id" || return 1
}

fm_pr_poll_retirement_recover_one() {
  local state=$1 id=$2 template=$3 receipt state_device check data registration
  local receipt_hash receipt_identity
  fm_pr_task_id_valid "$id" || return 1
  receipt="$state/$id.pr-poll-retirement"
  if [ ! -e "$receipt" ] && [ ! -L "$receipt" ]; then
    return 0
  fi
  if ! fm_pr_poll_retirement_state_valid "$state" "$id"; then
    fm_pr_poll_retirement_discard_obsolete "$state" "$id" "$template" && return 0
    return 1
  fi
  state_device=$(fm_pr_file_device "$state") || return 1
  check="$state/$id.check.sh"
  data="$state/$id.pr-poll"
  registration="$state/$id.pr-poll-registration"
  receipt_hash=$FM_PR_RETIRE_RECEIPT_HASH
  receipt_identity=$FM_PR_RETIRE_RECEIPT_IDENTITY
  if [ -e "$check" ] || [ -L "$check" ]; then
    fm_pr_poll_retirement_remove_exact "$check" "$state_device" \
      "$FM_PR_RETIRE_CHECK_IDENTITY" "$FM_PR_RETIRE_TEMPLATE_HASH" || return 1
  fi
  if [ -e "$registration" ] || [ -L "$registration" ]; then
    fm_pr_poll_retirement_remove_exact "$registration" "$state_device" \
      "$FM_PR_RETIRE_REG_IDENTITY" "$FM_PR_RETIRE_REG_HASH" || return 1
  fi
  if [ -e "$data" ] || [ -L "$data" ]; then
    fm_pr_poll_retirement_remove_exact "$data" "$state_device" \
      "$FM_PR_RETIRE_DATA_IDENTITY" "$FM_PR_RETIRE_DATA_HASH" || return 1
  fi
  fm_pr_poll_retirement_remove_exact "$receipt" "$state_device" \
    "$receipt_identity" "$receipt_hash" || return 1
  [ ! -e "$check" ] && [ ! -L "$check" ] \
    && [ ! -e "$registration" ] && [ ! -L "$registration" ] \
    && [ ! -e "$data" ] && [ ! -L "$data" ] \
    && [ ! -e "$receipt" ] && [ ! -L "$receipt" ]
}

fm_pr_poll_retirement_recover_all() {
  local state=$1 template=$2 receipt id
  FM_PR_POLL_RETIREMENT_REJECTED=
  for receipt in "$state"/*.pr-poll-retirement; do
    [ -e "$receipt" ] || [ -L "$receipt" ] || continue
    id=$(basename "$receipt" .pr-poll-retirement)
    if ! fm_pr_task_id_valid "$id" \
      || ! fm_pr_poll_retirement_recover_one "$state" "$id" "$template"; then
      FM_PR_POLL_RETIREMENT_REJECTED="$FM_PR_POLL_RETIREMENT_REJECTED $receipt"
    fi
  done
  [ -z "$FM_PR_POLL_RETIREMENT_REJECTED" ]
}

# --- merge-notification canonical-identity marker ----------------------------
# A merged-PR poll retires (fm_pr_poll_retirement_recover_one) in the same
# watcher cycle that detects it, which is normally enough on its own to stop a
# duplicate detection: the check.sh is gone, so nothing re-polls it. The
# exception is the same poll re-registered after its merge was already
# surfaced. Its retirement state is scoped to one registration, so this marker
# carries the canonical PR identity across registrations for the task. Only a
# matching identity is a no-op; a different PR for the same task reaches its
# role-routed supervision destination and replaces the marker when its first
# outcome is published.
fm_pr_poll_merge_marker_matches() {  # <marker> <device> <provider> <host> <path> <number>
  local marker=$1 device=$2 expected_provider=$3 expected_host=$4 expected_path=$5 expected_number=$6
  local version provider host path number
  fm_pr_private_file_valid "$marker" 600 "$device" || return 1
  exec 8< "$marker" || return 1
  IFS= read -r version <&8 || { exec 8<&-; return 1; }
  IFS= read -r provider <&8 || { exec 8<&-; return 1; }
  IFS= read -r host <&8 || { exec 8<&-; return 1; }
  IFS= read -r path <&8 || { exec 8<&-; return 1; }
  IFS= read -r number <&8 || { exec 8<&-; return 1; }
  if IFS= read -r _extra <&8; then
    exec 8<&-
    return 1
  fi
  exec 8<&-
  [ "$version" = fm-pr-poll-merge-notified-v1 ] \
    && [ "$provider" = "$expected_provider" ] \
    && [ "$host" = "$expected_host" ] \
    && [ "$path" = "$expected_path" ] \
    && [ "$number" = "$expected_number" ]
}

fm_pr_poll_merge_already_notified() {  # <state> <id> <provider> <host> <path> <number>
  local state=$1 id=$2 provider=$3 host=$4 path=$5 number=$6 marker state_device
  fm_pr_task_id_valid "$id" || return 1
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  state_device=$(fm_pr_file_device "$state") || return 1
  marker="$state/$id.pr-poll-merge-notified"
  fm_pr_poll_merge_marker_matches "$marker" "$state_device" \
    "$provider" "$host" "$path" "$number"
}

fm_pr_poll_merge_mark_notified() {  # <state> <id> <provider> <host> <path> <number>
  local state=$1 id=$2 provider=$3 host=$4 path=$5 number=$6 marker tmp state_device
  fm_pr_task_id_valid "$id" || return 1
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  state_device=$(fm_pr_file_device "$state") || return 1
  marker="$state/$id.pr-poll-merge-notified"
  fm_pr_regular_destination_on_device_or_absent "$marker" "$state_device" || return 1
  umask 077
  tmp=$(mktemp "$state/.fm-pr-poll-merge-notified.XXXXXX") || return 1
  if ! printf '%s\n%s\n%s\n%s\n%s\n' \
      fm-pr-poll-merge-notified-v1 "$provider" "$host" "$path" "$number" > "$tmp" \
    || ! chmod 0600 "$tmp" \
    || ! fm_pr_poll_merge_marker_matches "$tmp" "$state_device" \
      "$provider" "$host" "$path" "$number" \
    || ! fm_pr_regular_destination_on_device_or_absent "$marker" "$state_device" \
    || ! mv -f -- "$tmp" "$marker" \
    || ! fm_pr_poll_merge_marker_matches "$marker" "$state_device" \
      "$provider" "$host" "$path" "$number"; then
    rm -f -- "$tmp"
    return 1
  fi
}

# Removed at teardown alongside the other per-task PR-poll artifacts
# (bin/fm-teardown.sh) so a retired task id leaves no residue behind.
fm_pr_poll_merge_notified_remove() {  # <state> <id>
  local state=$1 id=$2 marker
  fm_pr_task_id_valid "$id" || return 1
  marker="$state/$id.pr-poll-merge-notified"
  [ -e "$marker" ] || [ -L "$marker" ] || return 0
  [ -f "$marker" ] && [ ! -L "$marker" ] || return 1
  rm -f -- "$marker"
}
