#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright © 2022 Government of Canada
#
# This script uses WP-CLI to import WordPress database, create admin user,
# and generate static HTML files using Simply Static plugin, for the
# Risk Profiler website to be published at https://www.riskprofiler.ca/

set -eo pipefail

import_db() {
	echo "Waiting for the db container to be ready..."
	bash /usr/local/bin/wait-for-it db:3306 -t 60

	if ! wp core is-installed; then
		echo "Importing WordPress database for RiskProfiler..."
		wp db import /usr/src/db-backup/wp_habitatseven_riskprofiler.sql
	else
		echo "WordPress database was previously installed, skipping import."
	fi
}

update_wp_core_and_simply_static() {
	# Updating WordPress core and Simply Static adds about 1 minute to the build.
	echo "Updating WordPress core and Simply Static plugin..."
	wp core update
	wp plugin update simply-static
	wp core update-db
}

create_wp_admin_user() {
	if [[ -n $WP_ADMIN_USER && -n $WP_ADMIN_EMAIL && -n $WP_ADMIN_PASSWORD ]]; then
		echo "Creating WordPress admin user \"${WP_ADMIN_USER}\"..."
		wp user create "${WP_ADMIN_USER}" "${WP_ADMIN_EMAIL}" --role=administrator --user_pass="${WP_ADMIN_PASSWORD}"
		echo "Updating admin email address to \"${WP_ADMIN_EMAIL}\"..."
		wp option update admin_email "${WP_ADMIN_EMAIL}"
	else
		echo "Warning: WP_ADMIN_{USER,EMAIL,PASSWORD} not defined."
		echo "         WordPress admin user not automatically created."
		echo "See"
		echo "https://developer.wordpress.org/cli/commands/user/create/WordPress"
	fi
}

configure_simply_static() {
	echo "Configuring Simply Static..."

	set -x
	wp option patch update simply-static 'temp_files_dir' '/var/www/html/site/assets/plugins/simply-static/static-files/'
	wp option patch update simply-static 'delivery_method' 'local'
	wp option patch update simply-static 'local_dir' '/var/www/html_static/simply-static-output/'

	# Link to e.g. ./scenarios/index.html instead of ./scenarios/
	wp option patch update simply-static 'destination_url_type' 'offline'
	wp option patch update simply-static 'use_cron' 'on'

	# "wp option patch update" would set 'debugging_mode' to integer 1,
	# but Simply Static recognizes only the string '1', hence "wp eval-file"
	wp eval-file - <<-'EOF'
		<?php
		$options = Simply_Static\Options::instance();
		$options
			->set( 'debugging_mode', '1' )
			->save();
	EOF

	wp option patch update simply-static 'additional_urls' <<-EOF
		http://riskprofiler.demo/favicon.ico
		http://riskprofiler.demo/site/assets/themes/fw-child/template/risks/detail.php
		http://riskprofiler.demo/site/assets/themes/fw-child/template/risks/filter.php
		http://riskprofiler.demo/site/assets/themes/fw-child/template/risks/items.php
		http://riskprofiler.demo/site/assets/themes/fw-child/template/scenarios/control-bar.php
		http://riskprofiler.demo/site/assets/themes/fw-child/template/scenarios/control-filter.php
		http://riskprofiler.demo/site/assets/themes/fw-child/template/scenarios/control-sort.php
		http://riskprofiler.demo/site/assets/themes/fw-child/template/scenarios/items.php
	EOF

	wp option patch update simply-static 'additional_files' <<-EOF
		/var/www/html/site/assets/themes/fw-child/resources/css/child.css.map
		/var/www/html/site/assets/themes/fw-child/resources/css/highcharts.css.map
		/var/www/html/site/assets/themes/fw-child/resources/vendor/Highcharts-9.3.3/code/highcharts.js.map
		/var/www/html/site/assets/themes/fw-child/resources/vendor/Highcharts-9.3.3/code/modules/export-data.js.map
		/var/www/html/site/assets/themes/fw-child/resources/vendor/Highcharts-9.3.3/code/modules/exporting.js.map
		/var/www/html/site/assets/themes/fw-child/resources/vendor/Leaflet.markercluster-1.4.1/dist/leaflet.markercluster.js.map
		/var/www/html/site/assets/themes/fw-parent/resources/css/global.css.map
		/var/www/html/site/assets/themes/fw-parent/resources/vendor/bootstrap/dist/js/bootstrap.bundle.min.js.map
		/var/www/html/site/assets/uploads/2021/10/lf20_mmrbfbcv.json
		/var/www/html/site/assets/uploads/2021/10/lf20_vx8bv90p.json
		/var/www/html/site/wp-includes/images/w-logo-blue-white-bg.png
	EOF

	# Remove old status values
	wp option patch delete simply-static 'archive_name'
	wp option patch delete simply-static 'archive_start_time'
	wp option patch delete simply-static 'archive_end_time'
	wp option patch delete simply-static 'archive_status_messages'

	# Show final configuration to the user
	set +x
	wp option get simply-static
}

simply_static_site_export() {
	set -x
	wp cron event schedule 'simply_static_site_export_cron'
	#wp cron event run 'simply_static_site_export_cron'
	wp cron event list
	wp cron event run --due-now
	set +x

	# Wait until Simply Static export finishes (normally less than 1 minute)
	timeout 2m bash -c "until wp option pluck simply-static 'archive_status_messages' 'done' >/dev/null; do sleep 1; done"
	# The export shouldn't get interrupted unless there are errors such as such as WP_SITEURL got set to http:///site/ (empty hostname).
	# Inserting "wp cron event run --all" to the wait loop above may be able to force the interrupted task to completion,
	# but the export may be incomplete, and should only be used in "emergency".

	# Show status messages from the completed Simply Static export run
	wp option pluck simply-static 'archive_status_messages'
}

fixup_static_site() {
	pushd /var/www/html_static
	if [[ -e riskprofiler ]]; then
		suffix=1
		while [[ -e riskprofiler.old.$suffix ]]; do
			suffix=$((suffix+1))
		done
		mv riskprofiler "riskprofiler.old.${suffix}"
	fi
	cp -a simply-static-output riskprofiler

	cd riskprofiler

	# The relative path to the animated logo is currently wrong in HTML files
	# in the second-level directory
	for i in */index.html; do
		sed -E -i 's#data-anim-path="\.\/site#data-anim-path="../site#' "${i}"
	done

	# Change PHP file paths to relative paths to allow serving from subdirectories
	sed -E -i "s#url: '/site#url: '../site#" site/assets/themes/fw-child/resources/js/profiler.js

	# Read and display names of scenarios from WordPress posts
	# Example: scenarios=([0]="georgia-strait" [1]="val-des-bois" [2]="cascadia-interface-best-fault" [3]="sidney" [4]="leech-river-full-fault")
	mapfile -t scenarios < <(wp post list --post_type=scenario --field=post_name)
	declare -p scenarios

	# Download scenario/ redirects
	for i in "${scenarios[@]}"; do
		mkdir -p "scenario/${i}"
		curl -o "scenario/${i}/index.html" "http://riskprofiler.demo/${i}/"
	done

	# Fix links to redirects
	sed -E -i 's#("url":")(https?:\\/\\/)?[^/]+/?#\1..\\/..\\/..\\/..\\/..\\/#' site/assets/themes/fw-child/template/scenarios/items.php
	sed -E -i 's#"url":".[^"]*#&index.html#' site/assets/themes/fw-child/template/scenarios/items.php

	popd
}

main() {
	echo "Running $0 as $(id -u):$(id -g)"

	# Set $HOME to somewhere writable so that e.g. "wp update core"
	# can write to $WP_CLI_CACHE_DIR which defaults to $HOME/.wp-cli/cache
	export HOME="/tmp/${UID}"
	mkdir -p "${HOME}"

	import_db
	create_wp_admin_user

	# Updating WordPress core and Simply Static would add about 1 minute to the build,
	# thus disabled by default.
	#update_wp_core_and_simply_static

	configure_simply_static
	simply_static_site_export
	fixup_static_site

	echo "Done!"
	echo
	echo "Raw static site export: html_static/simply-static-output/"
	echo " Site export debug log: wp-app/site/assets/plugins/simply-static/debug.txt"
	echo "  Fixed-up static site: html_static/riskprofiler/"

	if [[ "${KEEP_WPCLI_RUNNING,,}" =~ ^(true|1|y|yes|on)$ ]]; then
		echo
		echo "To enter the WP-CLI container, run:"
		echo "    docker exec -it riskprofiler-cms_wpcli_1 /bin/bash"
		sleep infinity
	fi
}

main "$@"
