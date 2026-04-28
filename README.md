# openstreetmap-tile-server

This image will start an Apache web server with [mod_tile](https://github.com/openstreetmap/mod_tile), which uses renderd/Mapnik to render tiles on the fly whenever they are requested for the first time. You need to provide a [CartoCSS](https://github.com/openstreetmap/mod_tile) `project.mml` file that defines the map style. If you do not provide such a file, the [openstreetmap-carto](https://github.com/openstreetmap-carto/openstreetmap-carto) style will be used.

This repository is a fork of [Overv/openstreetmap-tile-server](https://github.com/Overv/openstreetmap-tile-server). The main difference to the original is that this image does _not_ include a PostGIS database. Instead, it is intended to be used in conjunction with [osm2pgsql](https://osm2pgsql.org/), for example using the official [iboates/osm2pgsql](https://hub.docker.com/r/iboates/osm2pgsql) docker image. That will take care of importing OSM data into a PostGIS database and optionally keeping it up to date.

The main intention of creating this fork is to be able to run multiple tile servers that access the same PostGIS database, but using this image with a single tile server will still benefit from the improved architecture and up-to-date software versions. The approach is particularly useful for overlay maps. For example, one set of tiles that displays all the toll roads in the world should be published, and another set of tiles that shows all the cobble-stone roads. The actual geographic data for each of the sets will only be a few GB, as there are not that many of each type of road in the world. However, if continous updates of the database through replication should be enabled, osm2pgsql needs to persist several hundred GB of metadata that are required to remember the relationship between nodes and ways. With the original openstreetmap-tile-server, each of the tile servers would need to persist its own copy of that metadata, which would waste large amounts of space.

This page documents not only how to use openstreetmap-tile-server, but how to set up osm2pgsql to use both in combination.

## Setting up osm2pgsql

[osm2pgsql](https://osm2pgsql.org/) imports the OpenStreetMap database (the whole world or only a specific region) into a PostGIS (PostgreSQL with geographic extensions) database.

Since the OpenStreetMap database changes all the time, the PostGIS database needs to be updated regularly to avoid serving outdated data. There are two approaches for this. Either the whole database is recreated from time to time. Or a replication script frequently downloads only the changes since the last update and applies those to the database. With the second approach, you can even apply the latest changes every minute. When importing the OSM data, osm2pgsql needs to temporarily store the relationships between nodes and ways in order to construct the geometry of ways. This will occupy about 300 GiB of data for the whole planet (in 2026-04), regardless if you are only filtering out a small subset of objects. With the first approach, you can delete this temporary metadata after the import. This means that with the first approach, you can update your database less frequently, but less disk space is permanently consumed. With the second approach, you can update your database much more frequently, but a lot of disk space is permanently consumed.

### Without replication

Use the following docker-compose configuration to set up your PostGIS database:

```yaml
services:
    postgis:
        image: postgis/postgis:latest
        environment:
            POSTGRES_DB: o2p
            POSTGRES_USER: o2p
            POSTGRES_PASSWORD: o2p
        volumes:
            - ./postgis:/var/lib/postgresql/data
        healthcheck:
            test: pg_isready -d o2p -U o2p
            start_period: 60s
            start_interval: 1s
        restart: always

    import:
        image: iboates/osm2pgsql
        volumes:
            - ./styles:/styles:ro
            - ./data:/data
            - ./region.osm.pbf:/region.osm.pbf:ro
        environment:
            PGHOST: postgis
            PGDATABASE: o2p
            PGUSER: o2p
            PGPASSWORD: o2p
        links:
            - postgis
        depends_on:
            postgis:
                condition: service_healthy
        entrypoint: ""
        command: osm2pgsql -O flex -S /styles/main.lua --flat-nodes /data/flat_nodes.bin --slim --drop /region.osm.pbf
        profiles: [import]
```

You need to adjust the `osm2pgsql` command to your own needs. Here is an explanation of the parameters in the example:
* `-O flex -S /styles/flex.lua`: This assumes that you use the [Flex Output](https://osm2pgsql.org/doc/manual.html#the-flex-output) to filter and structure the OSM data according to your specific needs. Your flex output Lua script would be expected in `./styles/flex.lua`. Many projects still use the older [Pgsql Output](https://osm2pgsql.org/doc/manual.html#the-pgsql-output) with a style file and optionally a tag transformation Lua script (this is different from a Flex Output Lua script!). In that case you would need to adjust the arguments.
* `--flat-nodes /data/flat_nodes.bin`: This instructs osm2pgsql to store parts of the metadata in a binary file with a custom format while the import is running, rather than in the Postgres database. This make the import much faster and the size of the metadata much smaller.
* `--slim`: This means that the metadata should be stored in the Postgres database (and the flat nodes file) during the import, rather than in memory. If you happen to have at least around 300 GiB of memory, you can omit this option and the import will be much faster.
* `--drop`: This will delete the metadata when the import is complete. If you are not using replication, it is not needed anymore. The metadata is around 300 GB for the whole planet (in 2026-04).
* `/region.osm.pbf`: You can download the [whole planet](https://planet.openstreetmap.org/pbf/) or [a specific region](https://download.geofabrik.de/) and mount it here for import. Alternatively, you can specify the URL of the PBF file here directly, but then if something goes wrong during the import, the file will have to be downloaded again.

To start the PostGIS server, run `docker compose up -d`. To run the import, call `docker compose run --rm import`.

### With replication

To enable replication, use the following docker-compose configuration instead:

```yaml
services:
    postgis:
        image: postgis/postgis:latest
        environment:
            POSTGRES_DB: o2p
            POSTGRES_USER: o2p
            POSTGRES_PASSWORD: o2p
        volumes:
            - ./postgis:/var/lib/postgresql/data
        healthcheck:
            test: pg_isready -d o2p -U o2p
            start_period: 60s
            start_interval: 1s
        restart: always

    osm2pgsql:
        image: iboates/osm2pgsql
        volumes:
            - ./styles:/styles:ro
            - ./data:/data
        environment:
            PGHOST: postgis
            PGDATABASE: o2p
            PGUSER: o2p
            PGPASSWORD: o2p
            OSM2PGSQL_ARGS: -O flex -S /styles/main.lua --flat-nodes /data/flat_nodes.bin --slim
        links:
            - postgis
        depends_on:
            postgis:
                condition: service_healthy
        entrypoint: ""
        command: ["tail", "-f", "/dev/null"]
        restart: always

    cron:
        image: docker
        volumes:
            - /var/run/docker.sock:/var/run/docker.sock
            - ./crontab:/etc/crontabs/root:ro
        links:
            - osm2pgsql
        command: crond -f -d 7
        restart: always

    import:
        extends: osm2pgsql
        volumes:
            - ./region.osm.pbf:/region.osm.pbf:ro
        command: sh -c 'osm2pgsql $$OSM2PGSQL_ARGS /region.osm.pbf'
        profiles: [import]

```

In this case, the `osm2pgsql` container will not do anything itself, but it will only function as a container for `cron` to run its commands in.

Create the following `crontab` file:

```crontab
* * * * * docker exec postgis-osm2pgsql-1 osm2pgsql-replication update $OSM2PGSQL_ARGS 2>&1
# newline required at the end of file
```

The command in the crontab assumes that your docker-compose configuration is located in a folder called `postgis`, which results in the container name `postgis-osm2pgsql-1`. Adjust the container name to what ever your `osm2pgsql` container is called.

The crontab will run the replication script every minute. Feel free to configure a longer interval (for example use `*/10` instead of the first `*` for a 10-minute interval, or `0` for a 1-hour interval).

The first time you set all of this up, you still need to import the data first by running `docker compose run --rm import`. See the section [Without replication](#without-replication) for the details.


### Running multiple Lua scripts

If you want to run multiple tile servers or other services that require access to the OSM data, it makes sense for them to share the same PostGIS database so that the overhead of the osm2pgsql metadata is only consumed once. If your services all require access to most of the OSM data (for example you want to render several different map styles), it probably makes sense for them to access the same tables containing all the data, since those tables would be quite big and duplicating them would waste a lot of space. But if some of your services only require access to a small subset of the OSM data (for example overlays for toll roads or cobblestone roads), their tables would be quite small and it makes sense for each service to have its own tables. In the latter case, each service would have its own Lua script to import the data into its own tables.

osm2pgsql only allows to specify one Lua script. To not have to paste the contents of all processor functions together in one script, here is a Lua script that you can use as your `main.lua` script. It will import all the `*.lua` scripts in the same folder, and for each processor function, it will run the function with the same name exported by each of those scripts.

```lua
local script_name = debug.getinfo(1, "S").source:sub(2):match("([^/\\]+)$")
local script_path = debug.getinfo(1, "S").source:sub(2):match("(.*/)") or ""
package.path = script_path .. "?.lua;" .. package.path

local processors = {}
local handle = io.popen(string.format('ls -p "%s" | grep -v /', script_path))
if not handle then return end

for filename in handle:lines() do
    if filename:match("%.lua$") and filename ~= script_name then
        local module_name = filename:gsub("%.lua$", "")
        processors[module_name] = require(module_name)
    end
end

handle:close()

for _, func in ipairs({
    "process_node", "process_way", "process_relation",
    "process_untagged_node", "process_untagged_way", "process_untagged_relation",
    "process_deleted_node", "process_deleted_way", "process_deleted_relation"
}) do
    osm2pgsql[func] = function(object)
        for _, processor in ipairs(processors) do
            if processor[func] then
                processor[func](object)
            end
        end
    end
end
```

Here is an example `tolls.lua` script that would be put in the same folder and creates a table with toll roads:
```lua
local M = {};

local toll_lines = osm2pgsql.define_way_table('toll_lines', {
	{ column = 'osm_id',   type = 'int8', not_null = true },
	{ column = 'geom',     type = 'linestring', projection = 3857 }, -- Web Mercator
})

function M.process_way(object)
	if object.tags.toll == 'yes' and object.tags.route ~= 'ferry' then
		toll_lines:insert({
			osm_id = object.id,
			geom = object:as_linestring()
		})
	end
end

return M
```

As you can see, this script exports a local `process_way` function. `main.lua` would then call that function as part of the `osm2pgsql.process_way` processor.

## Setting up the tile server

Use the following docker-compose configuration to run the tile server:

```yaml
services:
    tileserver:
        image: facilmap/openstreetmap-tile-server
        volumes:
            - ./data:/data
            - ./style:/style:ro
        environment:
            ALLOW_CORS: enabled
        links:
            - postgis
        depends_on:
            postgis:
                condition: service_healthy
        restart: always
```

The container exposes its tiles on port `80`. To access them, set up a reverse proxy like traefik, or test the setup by publishing the port by using `ports: [8080:80]` for example.

The container expects to find the CartoCSS file in `/style/project.mml`. You can also use a different filename by setting the `NAME_MML` environment variable.

In the CartoCSS file, you need to configure the `Datasource` of your layers to use the PostGIS server (see its [documentation](https://cartocss.readthedocs.io/en/latest/mml.html#datasource). Here is an example:
```json
"Datasource": {
    "type": "postgis",
    "host": "postgis",
    "user": "o2p",
    "password": "o2p",
    "dbname": "o2p",
    "table": "toll_lines",
    "geometry_field": "geom"
}
```

The container will persist all its data, especially the rendered meta tiles, in its `/data` volume.

### Environment variables

| Variable | Default value | Description |
| -------- | ------------- | ----------- |
| `NAME_MML` | `project.mml` | File name of the CartoCSS file under `/style/`. |
| `THREADS` | `4` | Number of threads for the renderer to use. |
| `ALLOW_CORS` | `disabled` | Set to `enabled` to enable HTTP headers that allow cross-origin requests to the tiles. |

## License

```
Copyright 2019 Alexander Overvoorde
Copyright 2026 Candid Dauth

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    https://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
```
