# openstreetmap-tile-server

This image will start an Apache web server with [mod_tile](https://github.com/openstreetmap/mod_tile), which uses renderd/Mapnik to render tiles on the fly whenever they are requested for the first time. You need to provide one or more [CartoCSS](https://github.com/openstreetmap/mod_tile) `project.mml` files that define the map styles.

This repository is a fork of [Overv/openstreetmap-tile-server](https://github.com/Overv/openstreetmap-tile-server). There are some fundamental differences to the original:
* This image does _not_ include a PostGIS database. Instead, it is intended to be used in conjunction with [osm2pgsql](https://osm2pgsql.org/), for example using the official [iboates/osm2pgsql](https://hub.docker.com/r/iboates/osm2pgsql) docker image. That will take care of importing OSM data into a PostGIS database and optionally keeping it up to date.
* This image allows serving multiple maps with different style sheets.

Please [follow the tutorial](./docs/osm2pgsql.md) to set up a PostGIS database with an osm2pgsql import first. The following configuration assumes that this database is available as a container called `postgis`.

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

The container expects to find CartoCSS files in `/style/*/project.mml` (or a different filename if `NAME_MML` is set, see below). For each folder in `/style`, a different map is rendered. Please use sensible folder names that do not contain any spaces or special characters. When the container is started, all folders in `/style` are copied to `/data/style` and a `mapnik.xml` style is generated for each. The `/etc/renderd.conf` file is generated with all the configured maps on container start. If you want to provide a custom `renderd.conf`, you can mount one as read-only, which causes its generation to be skipped.

The container exposes its tiles on port `80`. To access them, set up a reverse proxy like traefik, or test the setup by publishing the port by using `ports: [8080:80]` for example. The tiles are served according to the name of their style folder, example, a map style configured in `/style/mymap` will be served under `/mymap/`. To show them on a Leaflet map for example, use `L.tileLayer("https://example.org/mymap/{z}/{x}/{y}.png", { maxZoom: 20 }).addTo(map)`. Accessing the tile server directly through the browser will show a demo page with a map containing all the configured map styles.

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

_TODO: The osm2pgsql-replication script marks tiles as expired. We still need to handle that expiration here._

### Environment variables

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
`

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
