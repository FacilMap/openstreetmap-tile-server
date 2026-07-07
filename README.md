# openstreetmap-tile-server

This Docker image will generate and serve map tiles using Mapnik. It will do the following:
* Start an Apache web server with [mod_tile](https://github.com/openstreetmap/mod_tile), which uses renderd/Mapnik to render tiles on the fly whenever they are requested for the first time.
* Compile one or more [CartoCSS](https://github.com/openstreetmap/mod_tile) `project.mml` files for you (with support for environment variables) and use them to generate the tiles.
* Serve a demo page where all the configured map styles can be viewed.
* Frequently read and clear the tile expiration table(s) to expire tiles when something has changed during live updates.

This image does _not_ import OpenStreetMap data and keep it up to date. By design, the PostGIS database and osm2pgsql import is separate from the tile server. There is a separate [tutorial](./docs/osm2pgsql.md) how to set those up.

This repository has started as a fork of [Overv/openstreetmap-tile-server](https://github.com/Overv/openstreetmap-tile-server). While it serves the same purpose, a lot has been changed from the original image.


## Setting up the tile server

First [follow the tutorial](./docs/osm2pgsql.md) to set up a PostGIS database and an osm2pgsql import. The following instructions assume that you have your PostGIS database running in a container called `postgis`.

Use the following docker-compose configuration to run the tile server:

```yaml
x-vars:
    - &database o2p
    - &user o2p
    - &password o2p

services:
    tileserver:
        image: facilmap/openstreetmap-tile-server
        volumes:
            - ./data:/data
            - ./style:/style:ro
        environment:
            ALLOW_CORS: enabled
            PGHOST: postgis
            PGDATABASE: *database
            PGUSER: *user
            PGPASSWORD: *password
        links:
            - postgis
        depends_on:
            postgis:
                condition: service_healthy
        restart: always
```

The container expects to find CartoCSS files in `/style/*/project.mml` (or a different filename if `NAME_MML` is set, see below). For each folder in `/style`, a different map is rendered. Please use sensible folder names that do not contain any spaces or special characters. When the container is started, all folders in `/style` are copied to `/data/style` and a `mapnik.xml` style is generated for each. The `/etc/renderd.conf` file is generated with all the configured maps on container start. If you want to provide a custom `renderd.conf`, you can mount one as read-only, which causes its generation to be skipped.

The container exposes its tiles on port `80`. To access them, set up a reverse proxy like traefik, or test the setup by publishing the port by using `ports: [8080:80]` for example. The tiles are served according to the name of their style folder, for example, a map style configured in `/style/mymap` will be served under `/mymap/`. To show them on a Leaflet map for example, use `L.tileLayer("https://example.org/mymap/{z}/{x}/{y}.png", { maxZoom: 20 }).addTo(map)`. Accessing the tile server directly through the browser will show a demo page with a map containing all the configured map styles.

In the CartoCSS file, you need to configure the `Datasource` of your layers to use the PostGIS server (see its [documentation](https://cartocss.readthedocs.io/en/latest/mml.html#datasource). Here is an example:
```json
"Datasource": {
    "type": "postgis",
    "host": "$PGHOST",
    "user": "$PGUSER",
    "password": "$PGPASSWORD",
    "dbname": "$PGDATABASE",
    "table": "toll_lines",
    "geometry_field": "geom"
}
```

The container will resolve any environment variables in your MML file (using `envsubst`, as carto does not seem to support this).

The container will persist all its data, especially the rendered meta tiles, in its `/data` volume.


### Tile expiration

If you have replication activated for your PostGIS database, it frequently imports the latest updates from the OpenStreetMap database. These updates cause tiles that have already been rendered and are now persisted in the cache to become outdated. In general, there are two ways to react to this: Either rerender the outdated tiles or delete them (so that they become rerendered on request). Deleting them will mean that users will have to wait several seconds for them to appear next time they view that part of the map, but rerendering them can mean a constant high memory and CPU usage, as especially on low zoom levels data changes somewhere all the time, and some of it might be for nothing if a rerendered tile expires again before anyone views it. In a typical setup, tiles are [prerendered](#prerender-tiles) up to a certain zoom level, and expired tiles up to that zoom level are rerendered and beyond that deleted.

openstreetmap-tile-server can handle an [expiration table](./docs/osm2pgsql.md#setting-up-tile-expiration) for each of your map styles. If such a table is found, it will be queried frequently, its tiles expired, and the table cleared. By default, an expiration table is expected to be called `${map}_expire`, where `${map}` is the name of the map style folder, with hyphens replaced by underscores. For example for a map style in `/style/cycling-restrictions`, the expiration table should be called `cycling_restrictions_expire`. This can be overridden by using the `EXPIRE_TABLE_mymap` [environment variable](#environment-variables). If this table is found, expiration is automatically enabled.

openstreetmap-tile-server will repeatedly check the expiration table and wait 60 seconds after the expiration has finished (in case of rerendering tiles it might take a while) before checking it again. You can configure this interval by setting the `EXPIRE_WAIT` [environment variable](#environment-variables).

By default, expired tiles for zoom levels 0–12 will be rerendered and tiles from zoom level 13 onwards will be deleted. You can configure this threshold by using the `EXPIRE_DELETE_FROM` [environment variable](#environment-variables).


### Prerender tiles

By default, openstreetmap-tile-server will render a tile when it is first requested and then cache it indefinitely (until it is expired). This means that when a user is viewing a section of the map that has never been viewed before, it will take a few seconds until that section becomes available. Sometimes it can take so long that a timeout occurs and the tiles are not shown until the user reloads the page after a while.

Generally, tiles at lower zoom levels tend to take longer to render, because each of them covers a bigger section of the map with a lot of data to load. At the same time, they are viewed more often, and there are much less of them in total. Because of all this, it is common practice to prerender all tiles up to a certain zoom level. The higher this zoom level, the (exponentially) more time and space the prerendering will take, at the benefit of the user experience.

openstreetmap-tile-server comes with a helper script that makes it easy to prerender the tiles. Run `docker compose exec tileserver prerender mymap --max-zoom=12` to prerender all tiles for the map style `mymap` up to zoom level 12. In general, it makes sense to prerender until one zoom level below what you have configured as `EXPIRE_DELETE_FROM` (13 by default). Here are some arguments that you can pass to `prerender`:
* `--max-zoom`: Prerender all tiles until this zoom level
* `--min-zoom`: Prerender all tiles from this zoom level (default `0`)
* `--max-load`: Rendering pauses while the load average of the server is higher than this (default `16`).

You can abort and resume the prerender script any time. It will only render tiles that are not in the cache yet.


### Environment variables

Some of the environment variables can be overridden for individual map styles. In the following table, `mymap` is used as an example folder name of an individual map style.

| Variable | Default value | Description |
| -------- | ------------- | ----------- |
| `NAME_MML` or `NAME_MML_mymap` | `project.mml` | File name of the CartoCSS file under `/style/`. Can be overridden for individual map styles. |
| `MAXZOOM` or `MAXZOOM_mymap` | `20` | Max zoom level to render. Can be overridden for individual map styles. |
| `THREADS` | `4` | Number of threads for the renderer to use. |
| `ALLOW_CORS` | `disabled` | Set to `enabled` to enable HTTP headers that allow cross-origin requests to the tiles. |
| `DEMO_MAPNIK` | `0` | `1`: Offer Mapnik layer on demo page; `2`: Offer and make visible by default. |
| `DEMO_VISIBLE` or `DEMO_VISIBLE_mymap` | `1` | Set to `0` to hide a particular (or all) map style by default on the demo page. |
| `DEMO_OPACITY` or `DEMO_OPACITY_mymap` | `1` | The opacity of the map style on the demo page. Example: `0.7` for overlays. |
| `DEMO_ZINDEX` or `DEMO_ZINDEX_mymap` | `1` | The z-index of the map style on the demo page. |
| `EXPIRE_TABLE_mymap` | `mymap_expire` | The name of the expiration table for each style. If the table does not exist, tile expiration is disabled for that style. The default value is `${map}_expire`, where `${map}` is the name of the style folder with hyphens replaced by underscores. |
| `EXPIRE_WAIT` | `60` | How many seconds to wait between each read of the tile expiration tables. |
| `EXPIRE_DELETE_FROM` | `13` | Tiles starting from this zoom level will be deleted instead of rerendered on expiration. |
| `PGHOST`, `PGPORT`, `PGUSER`, `PGPASSWORD`, `PGDATABASE` | | The [connection details](https://www.postgresql.org/docs/current/libpq-envars.html) to the PostGIS database to access the expiration table(s). Can also be used inside your MML file(s) (along with any other environment variables). |


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
