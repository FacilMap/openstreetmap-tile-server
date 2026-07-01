# Setting up osm2pgsql

[osm2pgsql](https://osm2pgsql.org/) imports the OpenStreetMap database (the whole world or only a specific region) into a PostGIS (PostgreSQL with geographic extensions) database.

Since the OpenStreetMap database changes all the time, the PostGIS database needs to be updated regularly to avoid serving outdated data. There are two approaches for this. Either the whole database is recreated from time to time. Or a replication script frequently downloads only the changes since the last update and applies those to the database. With the second approach, you can even apply the latest changes every minute. When importing the OSM data, osm2pgsql needs to temporarily store the relationships between nodes and ways in order to construct the geometry of ways. This will occupy about 300 GiB of data for the whole planet (in 2026-04), regardless if you are only filtering out a small subset of objects. With the first approach, you can delete this temporary metadata after the import. This means that with the first approach, you can update your database less frequently, but less disk space is permanently consumed. With the second approach, you can update your database much more frequently, but a lot of disk space is permanently consumed.

## Without replication

Use the following docker-compose configuration to set up your PostGIS database:

```yaml
x-vars:
    - &database o2p
    - &user o2p
    - &password o2p

services:
	postgis:
		image: postgis/postgis:latest
		environment:
			POSTGRES_DB: *database
            POSTGRES_USER: *user
            POSTGRES_PASSWORD: *password
		volumes:
			- ./postgis:/var/lib/postgresql/data
		healthcheck:
			test: pg_isready -h localhost -d $$POSTGRES_DB -U $$POSTGRES_USER
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
			PGDATABASE: *database
			PGUSER: *user
			PGPASSWORD: *password
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

## With replication

To enable replication, use the following docker-compose configuration instead:

```yaml
x-vars:
    - &database o2p
    - &user o2p
    - &password o2p

services:
	postgis:
		image: postgis/postgis:latest
		environment:
			POSTGRES_DB: *database
            POSTGRES_USER: *user
            POSTGRES_PASSWORD: *password
		volumes:
			- ./postgis:/var/lib/postgresql/data
		healthcheck:
			test: pg_isready -h localhost -d $$POSTGRES_DB -U $$POSTGRES_USER
			start_period: 60s
			start_interval: 1s
		restart: always

	import: &import
        image: iboates/osm2pgsql
        volumes:
            - .:/styles:ro
            - ./data/osm2pgsql:/data
            - ./region.osm.pbf:/region.osm.pbf:ro
        environment:
            PGHOST: postgis
            PGDATABASE: *database
            PGUSER: *user
            PGPASSWORD: *password
            OSM2PGSQL_ARGS: -O flex -S /styles/main.lua --flat-nodes /data/flat_nodes.bin --slim
        links:
            - postgis
        depends_on:
            postgis:
                condition: service_healthy
        entrypoint: ""
        command: sh -c 'osm2pgsql $$OSM2PGSQL_ARGS /region.osm.pbf'
        profiles: [import]

	replication:
        <<: *import
        volumes:
            - .:/styles:ro
            - ./data/osm2pgsql:/data
        command: sh -c 'while true; do osm2pgsql-replication update -- $$OSM2PGSQL_ARGS; sleep 60; done'
        restart: always
        profiles: []
```

The first time you set all of this up, you still need to import the data first by running `docker compose run --rm import`. See the section [Without replication](#without-replication) for the details.

After importing the data, run `docker compose run --rm replication osm2pgsql-replication init` to set up the replication. After that, start the `replication` container to apply live updates every 60 seconds (to change the interval, adjust the command).

When using replication, you also need to [set up tile expiration](#setting-up-tile-expiration) in your Lua script.


## Running multiple Lua scripts

If you want to run multiple tile servers or other services that require access to the OSM data, it makes sense for them to share the same PostGIS database so that the overhead of the osm2pgsql metadata is only consumed once. If your services all require access to most of the OSM data (for example you want to render several different map styles), it probably makes sense for them to access the same tables containing all the data, since those tables would be quite big and duplicating them would waste a lot of space. But if some of your services only require access to a small subset of the OSM data (for example overlays for toll roads or cobblestone roads), their tables would be quite small and it makes sense for each service to have its own tables. In the latter case, each service would have its own Lua script to import the data into its own tables.

osm2pgsql only allows to specify one Lua script. To not have to paste the contents of all processor functions together in one script, here is a Lua script that you can use as your `main.lua` script. It will import all the `*.lua` scripts in the same folder, and for each processor function, it will run the function with the same name exported by each of those scripts.

```lua
-- This Lua script combines all the scripts found under the following glob:
local scripts = "*.lua"
-- Each of those scripts must export a table that may contain any of the `process_node`, … functions as elements,
-- rather than assigning those to the global `osm2pgsql` global object as you normally would in an osm2pgsql script.

local script_name = debug.getinfo(1, "S").source:sub(2):match("([^/\\]+)$")
local script_path = debug.getinfo(1, "S").source:sub(2):match("(.*/)") or ""

local processors = {}
local handle = io.popen(string.format('ls -1p "%s"%s', script_path, scripts))
if not handle then return end

local package_path = package.path
for filename in handle:lines() do
    if filename:match("%.lua$") and filename ~= script_name then
        local module_name = filename:match("([^/]+)%.lua$")
        package.path = filename:match("(.*/)") .. "?.lua;" .. package_path
        processors[module_name] = require(module_name)
    end
end
package.path = package_path

handle:close()

for _, func in ipairs({
    "process_node", "process_way", "process_relation",
    "process_untagged_node", "process_untagged_way", "process_untagged_relation",
    "process_deleted_node", "process_deleted_way", "process_deleted_relation"
}) do
    local handlers = {}
    for _, processor in pairs(processors) do
        if processor[func] then
            table.insert(handlers, processor[func])
        end
    end

    if #handlers > 0 then
        osm2pgsql[func] = function(object)
            for _, handler in ipairs(handlers) do
                handler(object)
            end
        end
    end
end
```

Here is an example `tolls.lua` script that would be put in the same folder and creates a table with toll roads:
```lua
local M = {};

local tolls_lines = osm2pgsql.define_way_table('tolls_lines', {
	{ column = 'osm_id',   type = 'int8', not_null = true },
	{ column = 'geom',     type = 'linestring', projection = 3857 },
})

function M.process_way(object)
	if object.tags.toll == 'yes' then
		tolls_lines:insert({
			osm_id = object.id,
			geom = object:as_linestring()
		})
	end
end

return M
```

As you can see, this script exports a local `process_way` function. `main.lua` would then call that function as part of the `osm2pgsql.process_way` processor.

## Setting up tile expiration

The tile renderer renders the tiles as soon as they are requested and then keeps them cached for future requests. If you have replication enabled, tiles become outdated when any geometry contained on them is updated. For this, you need to set up an expiration table. If you run multiple tile renderers and have multiple Lua scripts for them, you can create a separate expiration tables for each one. This serves two purposes: Firstly, each renderer can clear out its own table as soon as _it_ has handled the expired tiles, and secondly, each expiration table can be specific to the actual geometries that the corresponding renderer handles.

Here is an example how you would define an expiration table and reference it in your geometry column:

```lua
local tolls_expire = osm2pgsql.define_expire_output({
	maxzoom = 20,
	table = 'tolls_expire'
})

local tolls_lines = osm2pgsql.define_way_table('tolls_lines', {
	{ column = 'osm_id',   type = 'int8', not_null = true },
	{ column = 'geom',     type = 'linestring', projection = 3857, expire = { { output = tolls_expire } } },
})
```