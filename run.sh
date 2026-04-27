#!/bin/bash

set -xeuo pipefail

rsync -rlt --delete /style/ /data/style/

MML_FILE="/data/style/$NAME_MML"
MAPNIK_XML=/data/style/mapnik.xml

if [ ! -e "$MML_FILE" ]; then
	echo "CartoCSS project not found. Please provide the file /style/$NAME_MML or set NAME_MML to a different filename." >&2
	exit 1
fi

# Compile MML file if mapnik.xml does not exist or it is older than the MML file
if [[ ! -f "$OUTPUT_FILE" ]] || [[ "$MML_FILE" -nt "$OUTPUT_FILE" ]]; then
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
sed -i -E "s/num_threads=[0-9]+/num_threads=${THREADS}/g" /etc/renderd.

if [ ! -e /data/tiles ]; then
	mkdir /data/tiles
fi
chown renderer:renderer /data/tiles

# Run while handling docker stop's SIGTERM
stop_handler() {
    kill -TERM "$child"
}
trap stop_handler SIGTERM

sudo -u renderer renderd -f -c /etc/renderd.conf &
child=$!
wait "$child"

exit 0
