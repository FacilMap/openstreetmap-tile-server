#!/bin/bash

set -xeuo pipefail

rsyslogd -n &
log_pid=$!

changes="$(rsync -inrlt --delete --exclude=/mapnik.xml /style/ /data/style/)"
if [ -n "$changes" ]; then
	rsync -rlt --delete --exclude=/mapnik.xml /style/ /data/style/
fi

MML_FILE="/data/style/$NAME_MML"
MAPNIK_XML=/data/style/mapnik.xml

if [ ! -e "$MML_FILE" ]; then
	echo "CartoCSS project not found. Please provide the file /style/$NAME_MML or set NAME_MML to a different filename." >&2
	exit 1
fi

# Compile MML file if mapnik.xml does not exist or there have been changes in the folder
if [[ ! -f "$MAPNIK_XML" ]] || [ -n "$changes" ]; then
	carto "$MML_FILE" > "$MAPNIK_XML"
	touch -r "$MML_FILE" "$MAPNIK_XML"
fi

# Clean /tmp
rm -rf /tmp/*

# Configure Apache CORS
if [ "${ALLOW_CORS}" == "enabled" ] || [ "${ALLOW_CORS}" == "1" ]; then
    echo "export APACHE_ARGUMENTS='-D ALLOW_CORS'" >> /etc/apache2/envvars
fi

service apache2 restart

# Configure renderd threads
sed -i -E "s/num_threads=[0-9]+/num_threads=${THREADS}/g" /etc/renderd.conf

if [ ! -e /data/tiles ]; then
	mkdir /data/tiles
fi
chown _renderd:_renderd /data/tiles

# Run while handling docker stop's SIGTERM
stop_handler() {
	service apache2 stop
	service renderd stop
	kill -TERM "$log_pid"
	exit 0
}
trap stop_handler SIGTERM

service renderd start

wait "$log_pid"