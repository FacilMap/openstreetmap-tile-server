#!/bin/bash

if [ ! -e "/style/$1" ]; then
	echo "Map style /style/$1 not found." >&2
	echo "Usage: $0 <map style> [args ...]" >&2
	exit 1
fi

exec render_list -a -c /etc/renderd.conf "--map=map-$1" "${@:2}"