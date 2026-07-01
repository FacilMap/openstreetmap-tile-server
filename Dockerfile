FROM ubuntu:26.04
ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8

RUN export DEBIAN_FRONTEND=noninteractive \
	&& apt-get update \
	&& apt-get -y upgrade \
	&& apt-get install -y --no-install-recommends \
		ca-certificates gnupg lsb-release locales \
		wget curl \
		git-core unzip unrar \
		apache2 \
		fonts-hanazono \
		fonts-noto-cjk \
		fonts-noto-hinted \
		fonts-noto-unhinted \
		fonts-unifont \
		# gettext needed for envsubst command
		gettext-base \
		jq \
		node-carto \
		postgresql \
		renderd \
		rsync \
		rsyslog \
		sudo \
	&& apt-get clean autoclean \
	&& apt-get autoremove --yes \
	&& rm -rf /var/lib/{apt,dpkg,cache,log}/ \
	&& locale-gen $LANG && update-locale LANG=$LANG

RUN ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone

# Get Noto Emoji Regular font, despite it being deprecated by Google
RUN wget https://github.com/googlefonts/noto-emoji/blob/9a5261d871451f9b5183c93483cbd68ed916b1e9/fonts/NotoEmoji-Regular.ttf?raw=true --content-disposition -P /usr/share/fonts/

# For some reason this one is missing in the default packages
RUN wget https://github.com/stamen/terrain-classic/blob/master/fonts/unifont-Medium.ttf?raw=true --content-disposition -P /usr/share/fonts/

# Configure rsyslog. Disable privilege drop so that it has write access to /dev/stdout.
RUN sed -i 's,^[$]PrivDrop,#$PrivDrop,g' /etc/rsyslog.conf \
	&& echo "*.* -/dev/stdout" > /etc/rsyslog.d/50-default.conf

# Configure Apache
RUN echo "LoadModule tile_module /usr/lib/apache2/modules/mod_tile.so" >> /etc/apache2/conf-available/mod_tile.conf \
	&& echo "LoadModule headers_module /usr/lib/apache2/modules/mod_headers.so" >> /etc/apache2/conf-available/mod_headers.conf \
	&& a2enconf mod_tile && a2enconf mod_headers \
	&& touch /etc/apache2/envvars.custom /etc/apache2/tile-configs.conf /var/www/html/maps.json \
	&& echo ". /etc/apache2/envvars.custom" >> /etc/apache2/envvars
COPY apache.conf /etc/apache2/sites-available/000-default.conf
RUN ln -sf /dev/stdout /var/log/apache2/access.log \
	&& ln -sf /dev/stderr /var/log/apache2/error.log

# leaflet
COPY leaflet-demo.html /var/www/html/index.html

COPY run.sh /usr/local/bin/
CMD ["/usr/local/bin/run.sh"]
EXPOSE 80
VOLUME /data

ENV NAME_MML=project.mml \
	THREADS=4 \
	ALLOW_CORS=disabled \
	MAXZOOM=20 \
	DEMO_OPACITY=1 \
	DEMO_VISIBLE=1 \
	DEMO_MAPNIK=0 \
	DEMO_ZINDEX=1 \
	EXPIRE_WAIT=60 \
	EXPIRE_DELETE_FROM=13