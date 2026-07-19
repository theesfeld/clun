#!/bin/sh

set -eu

output=
write_out=
url=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --output|--write-out|--header|--retry)
      option=$1
      shift
      [ "$#" -gt 0 ] || exit 2
      case "$option" in
        --output) output=$1 ;;
        --write-out) write_out=$1 ;;
        --header) printf 'header:%s\n' "$1" >>"$CLUN_TEST_CURL_LOG" ;;
      esac
      ;;
    --fail|--location|--silent|--show-error) ;;
    -*) ;;
    *) url=$1 ;;
  esac
  shift
done

[ -n "$url" ] || exit 2
printf 'url:%s\n' "$url" >>"$CLUN_TEST_CURL_LOG"

case "$url" in
  */releases/latest)
    [ -n "${CLUN_TEST_REDIRECT_TAG:-}" ] || exit 22
    case "$write_out" in
      *url_effective*)
        printf 'https://github.com/theesfeld/clun/releases/tag/%s' "$CLUN_TEST_REDIRECT_TAG"
        ;;
      *) exit 2 ;;
    esac
    ;;
  https://api.github.com/*)
    [ "${CLUN_TEST_API_STATUS:-200}" != 403 ] || exit 22
    if [ -n "${CLUN_TEST_API_JSON:-}" ]; then
      printf '%s\n' "$CLUN_TEST_API_JSON"
    else
      printf '[{"tag_name":"%s","draft":false,"prerelease":true}]\n' "$CLUN_TEST_API_TAG"
    fi
    ;;
  */releases.atom)
    [ -n "${CLUN_TEST_ATOM_XML:-}" ] || exit 22
    printf '%s\n' "$CLUN_TEST_ATOM_XML"
    ;;
  */releases/download/*)
    [ -n "$output" ] || exit 2
    cp "$CLUN_TEST_DIST_DIR/${url##*/}" "$output"
    ;;
  *) exit 22 ;;
esac
