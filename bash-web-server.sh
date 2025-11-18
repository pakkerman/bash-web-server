#!/usr/bin/env bash

PORT=8080
ADDRESS='0.0.0.0'
DIR='./example-site/'

read -d '' -r USAGE <<-EOF
Usage: bash-web-server [-p port] [-b address] [-d dir]

An HTTP server with Pure Bash.

Options
  -b <address>  Address to bind to, default to "0.0.0.0"
  -d <dir>      Directory to server, default to current dir.
  -h            Print this message.
  -p <port>     Port to bind, default 8080
EOF

fatal() {
  echo '[fatal]' "$@" >&2
  exit 1
}

mine-type() {
  local f=$1
  local bname=${f##*/}
  local ext=${bname##*.}
  [[ $bname == "$ext" ]] && ext=

  case "$ext" in
  html | htm) echo 'text/html' ;;
  jpeg | jpg) echo 'image/jpeg' ;;
  png) echo 'image/png' ;;
  txt) echo 'text/plain' ;;
  css) echo 'text/css' ;;
  js) echo 'text/javascript' ;;
  json) echo 'application/json' ;;
  *) echo 'application/octet-stream' ;;
  esac

}

html-encode() {
  local s=$1

  s=${s//&/\&amp;}
  s=${s//</\&lt;}
  s=${s//>/\&gt;}
  s=${s//\"/\&quot;}
  s=${s//\'/\&apos;}

  echo "$s"
}

list-directory() {
  local d=$1

  shopt -s nullglob dotglob

  echo '<h1>Directory Listing</h1>'
  echo "<h2>Directory: $(html-encode "$d")</h2>"
  echo '<hr>'
  echo '<ul>'
  for f in .. "$d"/*; do
    f=${f##*/}
    printf '<li><a href="%s">%s</a></li>\n' \
      "$(urlencode "$f")" \
      "$(html-encode "$f")"
  done

  echo '</ul>'
  echo '<hr>'

}

urlencode() {
  # Usage: urlencode "string"
  local LC_ALL=C
  for ((i = 0; i < ${#1}; i++)); do
    : "${1:i:1}"
    case "$_" in
    [a-zA-Z0-9.~_-])
      printf '%s' "$_"
      ;;

    *)
      printf '%%%02X' "'$_"
      ;;
    esac
  done
  printf '\n'
}

urldecode() {
  # Usage: urldecode "string"
  : "${1//+/ }"
  printf '%b\n' "${_//%/\\x}"
}

normalize-path() {
  local path=/$1

  local parts
  IFS='/' read -r -a parts <<<"$path"

  local -a part
  local -a out=()
  for part in "${parts[@]}"; do
    case "$part" in
    '') ;;                               # ignore empty directories (mulitple /)
    '.') ;;                              # ignore the current directory
    '..') unset 'out[-1]' 2>/dev/null ;; # delete the last item of the array, and throw error to null
    *) out+=("$part") ;;
    esac
  done

  local s
  s=$(
    IFS=/
    echo "${out[*]}"
  )

  echo "/$s"
}

parse-request() {
  declare -gA REQ_INFO=()
  declare -gA REQ_HEADERS=()

  local state='status'
  local line
  while read -r line; do
    line=${line%$'\r'}

    case "$state" in
    'status')
      # parse the status line
      # "GET /foo.txt HTTP/1.1"
      local method path version
      read -r method path version <<<"$line"
      REQ_INFO[method]=$method
      REQ_INFO[path]=$path
      REQ_INFO[version]=$version
      state='headers'
      ;;
    'headers')
      # parse the headers
      if [[ -z $line ]]; then
        # TODO: support body parsing
        break
      fi

      local key value
      IFS=':' read -r key value <<<"$line"
      key=${key,,}      # lower case, bash syntax
      value=${value# *} # '#' deleting left side of the string, ' ' targeting space char, '*' one or more matched
      REQ_HEADERS[$key]=$value
      ;;
    'body')
      fatal 'body parsing not supported'
      ;;

    esac
  done
}

process-request() {
  local fd=$1

  parse-request <&"$fd"

  # validate the request
  [[ ${REQ_INFO[version]} == 'HTTP/1.1' ]] || fatal 'unsupported HTTP Version'
  [[ ${REQ_INFO[method]} == 'GET' ]] || fatal 'unsupported HTTP Method'
  [[ ${REQ_INFO[path]} == /* ]] || fatal 'path must be absolute'

  echo "${REQ_INFO[method]} ${REQ_INFO[path]}"

  # if we are here, we should reply to the caller
  # "/././foo%20bar.txt?query=what"
  local path="${REQ_INFO[path]}"

  # "/././foo%20bar.txt?query=what"
  path=${path:1}

  # "././foo%20bar.txt"
  local query
  IFS='?' read -r path query <<<"$path"

  # "././foo bar.txt"
  path=$(urldecode "$path")

  # "/foo bar.txt"
  path=$(normalize-path "$path")

  # "foo bar.txt"
  path=${path:1}

  # handle empty path (root path)
  path=${path:-.}

  # try to serve an index page
  local to_try=(
    "$path"
    "$path/index.html"
    "$path/index.htm"
  )

  local try file
  for try in "${to_try[@]}"; do
    if [[ -f $try ]]; then
      file=$try
      break
    fi
  done

  if [[ -n $file ]]; then
    # a static file was found
    local mine
    mine=$(mine-type "$file")
    printf 'HTTP/1.1 200 OK\r\n' >&"$fd"
    printf 'Content-Type: %s\r\n' "$mine" >&"$fd"
    printf '\r\n' >&"$fd"
    tee <"$file" >&"$fd"

  elif [[ -d $path ]]; then
    # try a directory listing
    printf 'HTTP/1.1 200 OK\r\n' >&"$fd"
    printf 'Content-Type: text/html\r\n' >&"$fd"
    printf '\r\n' >&"$fd"
    list-directory "$path" >&"$fd"

  else
    # nothing was found
    printf 'HTTP/1.1 404 Not Found\r\n' >&"$fd"
    printf '\r\n' >&"$fd"

  fi
}

main() {
  enable -f ./loadable/socket_accept socket_accept || exit
  enable -f ./loadable/socket_listen socket_listen || exit
  enable tee || exit

  local OPTIND OPTARG opt
  while getopts 'b:hp:d:' opt; do
    case "$opt" in
    b) ADDRESS=$OPTARG ;;
    p) PORT=$OPTARG ;;
    d) DIR=$OPTARG ;;
    h)
      echo "$USAGE"
      exit 0
      ;;
    *) echo "$USAGE" exit 2 >&2 ;;
    esac
  done

  cd "$DIR" || fatal "Failed to move to $DIR"

  echo "Serving out of $DIR"
  echo "listening on http://$ADDRESS:$PORT"

  local fd
  socket_listen -b "$ADDRESS" -v fd "$PORT" || fatal 'failed to read socket'

  local client ip
  while true; do
    socket_accept -b "$ADDRESS" -v client -r ip "$fd" || fatal 'failed to read socket'

    process-request "$client" &
    exec {client}>&-
  done
}

main "$@"
