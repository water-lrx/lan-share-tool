#!/bin/sh
cd "$(dirname "$0")" || exit 1
URL="http://127.0.0.1:7999"

if curl -fsS --max-time 1 "$URL" >/dev/null 2>&1; then
  open "$URL"
  exit 0
fi

open "$URL"
/usr/bin/ruby app.rb
