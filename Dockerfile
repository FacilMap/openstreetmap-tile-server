FROM ubuntu:24.04 AS compiler-common
ENV LANG C.UTF-8
ENV LC_ALL C.UTF-8

RUN export DEBIAN_FRONTEND=noninteractive \
&& apt-get update \
&& apt-get install -y --no-install-recommends \
 ca-certificates gnupg lsb-release locales \
 wget curl \
 git-core unzip unrar \
&& locale-gen $LANG && update-locale LANG=$LANG \
&& apt-get -y upgrade

###########################################################################################################

FROM compiler-common AS compiler-stylesheet
RUN cd ~ \
&& git clone --single-branch --branch v5.4.0 https://github.com/gravitystorm/openstreetmap-carto.git --depth 1 \
&& cd openstreetmap-carto \
&& sed -i 's/, "unifont Medium", "Unifont Upper Medium"//g' style/fonts.mss \
&& sed -i 's/"Noto Sans Tibetan Regular",//g' style/fonts.mss \
&& sed -i 's/"Noto Sans Tibetan Bold",//g' style/fonts.mss \
&& sed -i 's/Noto Sans Syriac Eastern Regular/Noto Sans Syriac Regular/g' style/fonts.mss \
&& rm -rf .git

###########################################################################################################

FROM compiler-common AS final

RUN ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone

# Get packages
RUN export DEBIAN_FRONTEND=noninteractive \
&& apt-get install -y --no-install-recommends \
 apache2 \
 #cron \
 #dateutils \
 fonts-hanazono \
 fonts-noto-cjk \
 fonts-noto-hinted \
 fonts-noto-unhinted \
 fonts-unifont \
 #gnupg2 \
 #gdal-bin \
 #liblua5.3-dev \
 #lua5.3 \
 #mapnik-utils \
 node-carto \
 npm \
 #osm2pgsql \
 #osmium-tool \
 #osmosis \
 #postgis \
 #python-is-python3 \
 #python3-mapnik \
 #python3-lxml \
 #python3-psycopg2 \
 #python3-shapely \
 #python3-pip \
 renderd \
 rsync \
 sudo \
 #vim \
&& apt-get clean autoclean \
&& apt-get autoremove --yes \
&& rm -rf /var/lib/{apt,dpkg,cache,log}/

RUN adduser --disabled-password --gecos "" renderer

# Get Noto Emoji Regular font, despite it being deprecated by Google
RUN wget https://github.com/googlefonts/noto-emoji/blob/9a5261d871451f9b5183c93483cbd68ed916b1e9/fonts/NotoEmoji-Regular.ttf?raw=true --content-disposition -P /usr/share/fonts/

# For some reason this one is missing in the default packages
RUN wget https://github.com/stamen/terrain-classic/blob/master/fonts/unifont-Medium.ttf?raw=true --content-disposition -P /usr/share/fonts/

# Install python libraries
# RUN pip3 install \
#  requests \
#  osmium \
#  pyyaml

# Configure Apache
RUN echo "LoadModule tile_module /usr/lib/apache2/modules/mod_tile.so" >> /etc/apache2/conf-available/mod_tile.conf \
&& echo "LoadModule headers_module /usr/lib/apache2/modules/mod_headers.so" >> /etc/apache2/conf-available/mod_headers.conf \
&& a2enconf mod_tile && a2enconf mod_headers
COPY apache.conf /etc/apache2/sites-available/000-default.conf
RUN ln -sf /dev/stdout /var/log/apache2/access.log \
&& ln -sf /dev/stderr /var/log/apache2/error.log

# leaflet
COPY leaflet-demo.html /var/www/html/index.html
RUN cd /var/www/html/ \
&& wget https://github.com/Leaflet/Leaflet/releases/download/v1.8.0/leaflet.zip \
&& unzip leaflet.zip \
&& rm leaflet.zip

# Icon
RUN wget -O /var/www/html/favicon.ico https://www.openstreetmap.org/favicon.ico

# Create volume directories
RUN mkdir -p /run/renderd/ \
  &&  chown  -R  renderer:  /run/renderd  \
;

RUN echo '[default] \n\
URI=/tile/ \n\
TILEDIR=/data/tiles \n\
XML=/data/style/mapnik.xml \n\
HOST=localhost \n\
TILESIZE=256 \n\
MAXZOOM=20' >> /etc/renderd.conf \
 && sed -i 's,/usr/share/fonts/truetype,/usr/share/fonts,g' /etc/renderd.conf

COPY --from=compiler-stylesheet /root/openstreetmap-carto /style

COPY run.sh /usr/local/bin/
CMD ["/usr/local/bin/run.sh"]
EXPOSE 80
VOLUME /data
ENV NAME_MML=project.mml
ENV THREADS=4
ENV ALLOW_CORS=disabled