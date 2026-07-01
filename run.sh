#!/bin/bash

set -xeuo pipefail

rm -f /run/rsyslogd.pid
rsyslogd -n &
log_pid=$!

get_var() {
	local var="$1"
	local override="${var}_$2"

	if [[ -v "$override" ]]; then
		echo "${!override}"
	elif [[ $# -le 2 ]] || [[ -v "$var" ]]; then
		echo "${!var}"
	else
		echo "$3"
	fi
}

can_write() {
	path="$1"

	if ! [[ -w "$path" ]]; then
		echo "No write permission on /etc/apache2/tile-configs.conf, leaving untouched." >&2
		return 1
	fi

	return 0
}

# Clean /tmp
rm -rf /tmp/*

# Generate /etc/apache2/envvars.custom
if can_write /etc/apache2/envvars.custom; then
	# Configure Apache CORS
	if [ "${ALLOW_CORS}" == "enabled" ] || [ "${ALLOW_CORS}" == "1" ]; then
		echo "export APACHE_ARGUMENTS='-D ALLOW_CORS'" > /etc/apache2/envvars.custom
	else
		echo -n > /etc/apache2/envvars.custom
	fi
fi

mkdir -p /data/tiles
chown _renderd:_renderd /data/tiles

# Delete obsolete style directories
mkdir -p /data/style
for i in /data/style/*; do
	if [ ! -e "/style/$(basename "$i")" ]; then
		rm -rf "$i"
	fi
done

maps=( )

# Synchronize /style to /data/style and compile CartoCSS for folders where anything has changed
for path in /style/*/; do
	if [ ! -d "$path" ]; then # No files in /style, $path is /style/*/
		continue
	fi

	i="$(basename "$path")"
	name_mml="$(get_var NAME_MML "$i")"
	if [ ! -e "/style/$i/$name_mml" ]; then
		echo "CartoCSS project /style/$i/$name_mml not found, ignoring folder. If this is a mistake, provide the file or set NAME_MML_$i or NAME_MML to a different filename." >&2
		continue
	fi

	maps+=( "$i" )

	changes="$(rsync -inrlt --delete --exclude=/mapnik.xml "/style/$i/" "/data/style/$i/")"
	if [ -n "$changes" ]; then
		rsync -rlt --delete --exclude=/mapnik.xml "/style/$i/" "/data/style/$i/"
	fi

	MML_FILE="/data/style/$i/$name_mml"
	MML_OUT_FILE="/data/style/$i/.project.out.mml"
	MAPNIK_XML=/data/style/$i/mapnik.xml

	# Compile MML file if mapnik.xml does not exist or there have been changes in the folder
	if [[ ! -f "$MAPNIK_XML" ]] || [ -n "$changes" ]; then
		rm -f "$MAPNIK_XML" # Delete it so that if carto fails, it is rerun the next time
		cat "$MML_FILE" | envsubst > "$MML_OUT_FILE"
		carto "$MML_OUT_FILE" -f "$MAPNIK_XML"
		rm -f "$MML_OUT_FILE"
		touch -r "$MML_FILE" "$MAPNIK_XML"
	fi
done

# Generate /etc/renderd.conf
if can_write /etc/renderd.conf; then
	(
		cat <<EOF
[renderd]
stats_file=/run/renderd/renderd.stats
socketname=/run/renderd/renderd.sock
num_threads=$THREADS
tile_dir=/data/tiles

[mapnik]
plugins_dir=/usr/lib/mapnik/3.1/input
font_dir=/usr/share/fonts
font_dir_recurse=true
EOF

		for i in "${maps[@]}"; do
			maxzoom="$(get_var MAXZOOM "$i")"
			cat <<EOF

[map-$i]
URI=/$i/
XML=/data/style/$i/mapnik.xml
HOST=localhost
TILESIZE=256
MAXZOOM=$maxzoom
EOF
		done
	) > /etc/renderd.conf
fi

# Generate /etc/apache2/tile-configs.conf
if can_write /etc/apache2/tile-configs.conf; then
	(
		for i in "${maps[@]}"; do
			echo "AddTileConfig /$i/ map-$i"
		done
	) > /etc/apache2/tile-configs.conf
fi

# Generate /var/www/html/maps.json
if can_write /var/www/html/maps.json; then
	json="$(echo '{"maps":{}}' | jq --argjson mapnik "$DEMO_MAPNIK" '.mapnik = $mapnik')"
	for i in "${maps[@]}"; do
		maxzoom="$(get_var MAXZOOM "$i")"
		opacity="$(get_var DEMO_OPACITY "$i")"
		zindex="$(get_var DEMO_ZINDEX "$i")"
		visible="$(get_var DEMO_VISIBLE "$i")"
		[[ "$visible" = 1 ]] && visible_bool=true || visible_bool=false
		json="$(echo "$json" | jq --arg i "$i" --argjson maxzoom "$maxzoom" --argjson opacity "$opacity" --argjson zindex "$zindex" --argjson visible "$visible_bool" '.maps.[$i] = { "maxZoom": $maxzoom, "opacity": $opacity, "zIndex": $zindex, "visible": $visible }')"
	done

	echo "$json" > /var/www/html/maps.json
fi

# Run while handling docker stop's SIGTERM
stop_handler() {
	service apache2 stop
	service renderd stop
	kill -TERM "$log_pid"
	exit 0
}
trap stop_handler SIGTERM

service renderd start
service apache2 start

declare -A expire_tables
for i in "${maps[@]}"; do
	expire_table="$(get_var EXPIRE_TABLE "$i" "${i//-/_}_expire")"

	if psql -Aqtc "SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = '${expire_table}';" | grep -q 1; then
		echo "Using expire table ${expire_table} for ${i}" >&2
		expire_tables["$i"]="$expire_table"
	else
		echo "Expire table ${expire_table} for ${i} not found, disabling tile expiration." >&2
	fi
done

while true; do
	for i in "${!expire_tables[@]}"; do
		date="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
		if psql -Aqtc "select zoom || '/' || x || '/' || y from \"${expire_tables["$i"]}\" where last <= '${date}';" | render_expired -m "map-$i" -c /etc/renderd.conf -d "$EXPIRE_DELETE_FROM"; then
			if ! psql -Aqtc "delete from \"${expire_tables["$i"]}\" where last <= '${date}';"; then
				echo "Cleaning up expiration table for $i failed." >&2
			fi
		else
			echo "Expiring tiles for $i failed." >&2
		fi
	done

	sleep "$EXPIRE_WAIT"
done