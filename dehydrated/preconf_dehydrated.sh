#!/usr/bin/env bash
set -euo pipefail

CUR_DIR=$(pwd)
if [ -z "${DFL_FQDN:-}" ]; then
	if [ $# -eq 1 ]; then
		DFL_FQDN=${1:-}
	else
		echo "Server's default FQDN not supplied." >&2
		echo "Please set DFL_FQDN or run '$0 <default.server.fqdn>'." >&2 
		exit 1
	fi
fi
echo "Default domain: '${DFL_FQDN}'"

mkdir -p /var/www/dehydrated
chown www-data:www-data /var/www/dehydrated

if [ -d /etc/apache2 ]; then
	if [ ! -d /etc/apache2/tls-conf ]; then
		mkdir -p /etc/apache2/tls-conf
		cat > /etc/apache2/tls-conf/dehydrated.conf <<'EOF'
Alias /.well-known/acme-challenge /var/www/dehydrated
<Directory /var/www/dehydrated>
        Options None
        AllowOverride None
        Require all granted
</Directory>
EOF
	fi

	# Patch default-ssl.conf
	DFL_SEC_VHOST=/etc/apache2/sites-available/default-ssl.conf
	INCLUDE_REGEX="s/^([[:space:]]+)(SSLEngine[[:space:]]+on)/\1\2\n\1Include tls-conf\/$(echo $DFL_FQDN | sed 's/\./\\\./g').conf/g"
	sed -i -E 's/^([[:space:]]+)(SSLCertificateFile|SSLCertificateKeyFile)/\1#\2/g' "${DFL_SEC_VHOST}"
	sed -i -E "${INCLUDE_REGEX}" "${DFL_SEC_VHOST}"

	# Generate the default vhost tls-config 
	DFL_TLSCONF=/etc/apache2/tls-conf/${DFL_FQDN}.conf
	if [ ! -f "${DFL_TLSCONF}" ]; then
		cat > "${DFL_TLSCONF}" <<EOF
SSLCertificateFile    	/etc/dehydrated/certs/${DFL_FQDN}/cert.pem
SSLCertificateKeyFile 	/etc/dehydrated/certs/${DFL_FQDN}/privkey.pem
SSLCertificateChainFile /etc/dehydrated/certs/${DFL_FQDN}/chain.pem
EOF
	fi
fi

cd /usr/local/src/
if [ ! -d "./dehydrated" ]; then
	git clone "https://github.com/dehydrated-io/dehydrated"
	cd dehydrated
	latest_tag=$(git tag -l 'v*' --sort=-v:refname | head -n1)
	git checkout "${latest_tag}"
	cd ..
fi

if [ -d "${CUR_DIR}/dehydrated" ]; then
	# Restore the existing dehydrated config
	cp -rp "${CUR_DIR}/dehydrated" /etc/dehydrated
else
	# Bootstrap config from repository
	mkdir -p /etc/dehydrated
	echo "${DFL_FQDN}" > /etc/dehydrated/domains.txt
	cat > /etc/dehydrated/config <<'EOF'
CA="letsencrypt"
CHALLENGETYPE="http-01"
BASEDIR=/etc/dehydrated
DOMAINS_TXT="${BASEDIR}/domains.txt"
CERTDIR="${BASEDIR}/certs"
ALPNCERTDIR="${BASEDIR}/alpn-certs"
ACCOUNTDIR="${BASEDIR}/accounts"
WELLKNOWN="/var/www/dehydrated"
HOOK="${BASEDIR}/hook.sh"
RENEW_DAYS="30"
PRIVATE_KEY_RENEW="yes"
KEY_ALGO=secp384r1
LOCKFILE="${BASEDIR}/lock"
CHAINCACHE="${BASEDIR}/chains"
AUTO_CLEANUP="yes"
EOF

	cat > /etc/dehydrated/hook.sh <<'EOF'
#!/usr/bin/env bash

exit_hook() {
	echo "Running exit hooks to reload impacted services"

	# Reload apache if available
	which apache2ctl &> /dev/null
	if [[ "$?" == "0" ]]; then

		# Check Apache config before attempting reload
		$(which apache2ctl) configtest &> /dev/null
		if [[ "$?" == "0" ]]; then
			$(which systemctl) reload apache2
			if [[ "$?" != "0" ]]; then
				echo " + Failed to reload apache."
			else
				echo " + Apache reloaded successfully."
			fi
		else
			echo " + Apache reload skipped due to corrupt config."
		fi
	fi

	# Reload Postfix if available
	which postfix &> /dev/null
	if [[ "$?" == "0" ]]; then
		$(which postfix) check &> /dev/null
		if [[ "$?" == "0" ]]; then
			$(which systemctl) reload postfix
			if [[ "$?" != "0" ]]; then
				echo " + Failed to reload postfix."
			else
				echo " + Postfix reloaded successfully."
			fi
		else
			echo " + Postfix reload skipped due to corrupt config."
		fi
	fi

	# Reload Dovecot if available
	which doveconf &> /dev/null
	if [[ "$?" == "0" ]]; then
		$(which doveconf) -n &> /dev/null
		if [[ "$?" == "0" ]]; then
			$(which systemctl) reload dovecot
			if [[ "$?" != "0" ]]; then
				echo " + Failed to reload dovecot."
			else
				echo " + Dovecot reloaded successfully."
			fi
		else
			echo " + Dovecot reload skipped due to corrupt config."
		fi
	fi
}

HANDLER="$1"; shift
if [[ "${HANDLER}" =~ ^exit_hook$ ]]; then
	"$HANDLER" "$@"
fi
EOF
	chmod +x /etc/dehydrated/hook.sh

	# Register and accept terms
	/usr/local/src/dehydrated/dehydrated --register --accept-terms

	# Add crontab
	cat > /etc/cron.d/dehydrated <<'EOF'
27 4 * * * root /usr/local/src/dehydrated/dehydrated -c
EOF
fi

# Run dehydrated immediately.
/usr/local/src/dehydrated/dehydrated -c

cd "${CUR_DIR}"
